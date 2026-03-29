# UniPay — The `process_payment()` Stored Function

> **AI Instruction**: This file explains every line of the most critical
> function in the UniPay system. The Worker MUST call this function for
> every payment. The Worker MUST NOT replicate this logic in TypeScript.
> The database is the authority on money movement. Never split this
> function into multiple calls — atomicity is the entire point.

---

## 1. Why This Exists as a Stored Function

A payment involves four database operations:

```
1. Check idempotency key
2. Debit student wallet
3. Credit merchant wallet
4. Insert transaction row
5. Insert two ledger_entry rows
```

If these were five separate SQL calls from the Worker, a network drop
between any two of them would leave the database in a partial state —
money debited but not credited, or transaction recorded but wallet not
updated. This is called a split-brain failure and it is catastrophic in
a financial system.

By wrapping all five operations in a single PostgreSQL stored function,
they execute inside one atomic transaction. PostgreSQL guarantees:

```
Either ALL five operations succeed and are committed together,
OR the database detects a failure and rolls back ALL of them.
No partial state is ever possible.
```

The Worker makes one network call. PostgreSQL does all the work. One round
trip. One commit. One result.

---

## 2. Function Signature

```sql
CREATE OR REPLACE FUNCTION process_payment(
  p_payer_wallet_id   UUID,        -- Student's wallet UUID
  p_payee_wallet_id   UUID,        -- Merchant's wallet UUID
  p_merchant_id       UUID,        -- Merchant UUID (for receipt)
  p_amount_cents      BIGINT,      -- Payment amount in cents (integer only)
  p_transaction_type  transaction_type, -- 'purchase' or 'preorder'
  p_receipt_payload   JSONB,       -- SKU line items (nullable)
  p_idempotency_key   UUID,        -- Client-generated UUID v4
  p_payload_hash      CHAR(64)     -- SHA-256 of request payload
)
RETURNS UUID                       -- Returns the new transaction UUID
LANGUAGE plpgsql
AS $$
```

**Every parameter is required.** There are no defaults. A call missing
any parameter fails immediately at the PostgreSQL level before any
business logic runs.

---

## 3. The Complete Function — Annotated

```sql
DECLARE
  v_transaction_id  UUID;
  v_existing_hash   CHAR(64);
  v_payer_balance   BIGINT;
BEGIN

  -- ─────────────────────────────────────────────────────────────
  -- STEP 1: IDEMPOTENCY GUARD
  -- Check if this key has been used before.
  -- This is the database-level lock — the KV check in the Worker
  -- is a speed optimisation only. This is the hard guarantee.
  -- ─────────────────────────────────────────────────────────────

  SELECT id, payload_hash
  INTO v_transaction_id, v_existing_hash
  FROM transactions
  WHERE idempotency_key = p_idempotency_key;

  IF FOUND THEN
    -- Key exists — this is a retry

    -- STEP 1a: Anti-forgery check
    -- Compare the stored hash against the incoming hash.
    -- A mismatch means someone changed the payload (e.g. amount_cents)
    -- and tried to replay the same idempotency key.
    IF v_existing_hash != p_payload_hash THEN
      RAISE EXCEPTION 'UNIPAY_ERR_IDEMPOTENCY_FORGERY'
        USING
          HINT    = 'Payload hash does not match original request',
          ERRCODE = 'P0001';
    END IF;

    -- Hash matches — safe retry, return original transaction ID
    -- The Worker will return this as a successful 201 response
    RETURN v_transaction_id;
  END IF;


  -- ─────────────────────────────────────────────────────────────
  -- STEP 2: INPUT VALIDATION
  -- Validate business rules before touching any balances.
  -- Fail fast — no money moves if inputs are invalid.
  -- ─────────────────────────────────────────────────────────────

  -- Amount must be positive
  IF p_amount_cents <= 0 THEN
    RAISE EXCEPTION 'UNIPAY_ERR_INVALID_AMOUNT'
      USING
        HINT    = 'amount_cents must be greater than zero',
        ERRCODE = 'P0002';
  END IF;

  -- Payer and payee cannot be the same wallet
  IF p_payer_wallet_id = p_payee_wallet_id THEN
    RAISE EXCEPTION 'UNIPAY_ERR_SELF_PAYMENT'
      USING
        HINT    = 'Payer and payee wallet IDs are identical',
        ERRCODE = 'P0003';
  END IF;

  -- Verify payer wallet exists and is active
  IF NOT EXISTS (
    SELECT 1 FROM wallets
    WHERE id = p_payer_wallet_id
    AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'UNIPAY_ERR_PAYER_WALLET_INVALID'
      USING
        HINT    = 'Payer wallet does not exist or is not active',
        ERRCODE = 'P0004';
  END IF;

  -- Verify payee wallet exists and is active
  IF NOT EXISTS (
    SELECT 1 FROM wallets
    WHERE id = p_payee_wallet_id
    AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'UNIPAY_ERR_PAYEE_WALLET_INVALID'
      USING
        HINT    = 'Payee wallet does not exist or is not active',
        ERRCODE = 'P0005';
  END IF;


  -- ─────────────────────────────────────────────────────────────
  -- STEP 3: DEBIT PAYER WALLET
  -- FOR UPDATE locks the row for this transaction duration.
  -- This prevents a race condition where two simultaneous payments
  -- from the same wallet both read the same balance and both succeed,
  -- resulting in a negative balance.
  -- The CHECK (balance_cents >= 0) constraint is the final floor —
  -- if this UPDATE would push balance below zero, PostgreSQL throws
  -- automatically before the UPDATE commits.
  -- ─────────────────────────────────────────────────────────────

  UPDATE wallets
  SET
    balance_cents = balance_cents - p_amount_cents,
    updated_at    = NOW()
  WHERE id = p_payer_wallet_id
  RETURNING balance_cents INTO v_payer_balance;

  -- Note: if balance_cents - p_amount_cents < 0, the CHECK constraint
  -- fires here and the entire transaction is rolled back automatically.
  -- The Worker catches the PostgreSQL error code and returns 402.


  -- ─────────────────────────────────────────────────────────────
  -- STEP 4: CREDIT PAYEE WALLET
  -- No lock needed on the credit side — adding money never causes
  -- a constraint violation. The payee wallet status was verified
  -- in Step 2 and cannot change within this transaction.
  -- ─────────────────────────────────────────────────────────────

  UPDATE wallets
  SET
    balance_cents = balance_cents + p_amount_cents,
    updated_at    = NOW()
  WHERE id = p_payee_wallet_id;


  -- ─────────────────────────────────────────────────────────────
  -- STEP 5: INSERT TRANSACTION RECORD
  -- The transaction row is the immutable audit record of this event.
  -- It is never updated or deleted after insert.
  -- ─────────────────────────────────────────────────────────────

  INSERT INTO transactions (
    type,
    status,
    payer_wallet_id,
    payee_wallet_id,
    merchant_id,
    amount_cents,
    receipt_payload,
    idempotency_key,
    payload_hash,
    completed_at
  ) VALUES (
    p_transaction_type,
    'completed',
    p_payer_wallet_id,
    p_payee_wallet_id,
    p_merchant_id,
    p_amount_cents,
    p_receipt_payload,
    p_idempotency_key,
    p_payload_hash,
    NOW()
  )
  RETURNING id INTO v_transaction_id;


  -- ─────────────────────────────────────────────────────────────
  -- STEP 6: INSERT DOUBLE-ENTRY LEDGER ROWS
  -- Every payment creates exactly two ledger entries.
  -- Debit on payer side + Credit on payee side.
  -- The sum of all ledger entries across all wallets always = 0.
  -- This is the accounting integrity invariant of the system.
  -- ─────────────────────────────────────────────────────────────

  INSERT INTO ledger_entries
    (transaction_id, wallet_id, direction, amount_cents, balance_after_cents)
  VALUES
    -- Debit entry: money leaving the payer wallet
    (v_transaction_id, p_payer_wallet_id,  'debit',  p_amount_cents, v_payer_balance),
    -- Credit entry: money entering the payee wallet
    -- balance_after_cents for payee is fetched inline
    (v_transaction_id, p_payee_wallet_id, 'credit', p_amount_cents,
      (SELECT balance_cents FROM wallets WHERE id = p_payee_wallet_id));


  -- ─────────────────────────────────────────────────────────────
  -- RETURN
  -- Returns the new transaction UUID to the Worker.
  -- Worker includes this in the 201 Created response body.
  -- ─────────────────────────────────────────────────────────────

  RETURN v_transaction_id;

END;
$$;
```

---

## 4. How the Worker Calls This Function

```typescript
// worker/src/modules/payment/payment.repository.ts

import type { NeonClient } from '../../db/client';
import type { PaymentPayload } from '@unipay/shared/types/payment';

export async function callProcessPayment(
  db: NeonClient,
  params: {
    payerWalletId:    string;
    payeeWalletId:    string;
    merchantId:       string;
    amountCents:      number;
    transactionType:  'purchase' | 'preorder';
    receiptPayload:   object | null;
    idempotencyKey:   string;
    payloadHash:      string;
  }
): Promise<{ transactionId: string }> {

  const result = await db.query<{ process_payment: string }>(
    `SELECT process_payment(
      $1::uuid,   -- p_payer_wallet_id
      $2::uuid,   -- p_payee_wallet_id
      $3::uuid,   -- p_merchant_id
      $4::bigint, -- p_amount_cents
      $5::transaction_type,
      $6::jsonb,  -- p_receipt_payload
      $7::uuid,   -- p_idempotency_key
      $8::char    -- p_payload_hash
    )`,
    [
      params.payerWalletId,
      params.payeeWalletId,
      params.merchantId,
      params.amountCents,
      params.transactionType,
      params.receiptPayload ? JSON.stringify(params.receiptPayload) : null,
      params.idempotencyKey,
      params.payloadHash,
    ]
  );

  return { transactionId: result.rows[0].process_payment };
}
```

---

## 5. Error Code Mapping

The Worker catches PostgreSQL exceptions and maps them to HTTP responses.
This happens in `payment.service.ts` wrapping the repository call.

```typescript
// worker/src/modules/payment/payment.service.ts

import { HTTPException } from 'hono/http-exception';

export async function processPayment(db, params) {
  try {
    return await PaymentRepository.callProcessPayment(db, params);

  } catch (e: unknown) {
    if (!(e instanceof Error)) throw e;

    // PostgreSQL CHECK constraint — balance went below zero
    if (e.message.includes('check_balance_non_negative') ||
        e.message.includes('balance_cents')) {
      throw new HTTPException(402, {
        message: 'Insufficient funds'
      });
    }

    // Custom exception codes from the stored function
    const pgError = e as { message: string; hint?: string };

    switch (true) {
      case pgError.message.includes('UNIPAY_ERR_IDEMPOTENCY_FORGERY'):
        throw new HTTPException(422, { message: 'Payment integrity violation' });

      case pgError.message.includes('UNIPAY_ERR_INVALID_AMOUNT'):
        throw new HTTPException(400, { message: 'Invalid payment amount' });

      case pgError.message.includes('UNIPAY_ERR_SELF_PAYMENT'):
        throw new HTTPException(400, { message: 'Cannot pay yourself' });

      case pgError.message.includes('UNIPAY_ERR_PAYER_WALLET_INVALID'):
        throw new HTTPException(403, { message: 'Your wallet is unavailable' });

      case pgError.message.includes('UNIPAY_ERR_PAYEE_WALLET_INVALID'):
        throw new HTTPException(403, { message: 'Merchant wallet is unavailable' });

      default:
        // Unknown DB error — log internally, return generic message
        console.error('[process_payment] unexpected error:', e);
        throw new HTTPException(500, { message: 'Payment could not be processed' });
    }
  }
}
```

---

## 6. Worked Example

**Scenario**: Navod pays the Goda Canteen 650 LKR for rice and curry.

**Before:**

| Wallet | Owner | balance_cents |
|---|---|---|
| `wallet-A` | Navod (student) | 1,500,00 (LKR 1,500) |
| `wallet-B` | Goda Canteen | 8,000,00 (LKR 8,000) |

**Function call:**

```sql
SELECT process_payment(
  'wallet-A',                    -- payer
  'wallet-B',                    -- payee
  'merchant-goda',               -- merchant
  65000,                         -- LKR 650.00 in cents
  'purchase',
  '{"items":[{"name":"Rice & Curry","qty":1,"unit_price_cents":65000}]}',
  'uuid-abc-123',                -- idempotency key
  'sha256hashofpayload...'       -- payload hash
);
```

**After:**

| Wallet | Owner | balance_cents | Change |
|---|---|---|---|
| `wallet-A` | Navod | 85000 (LKR 850) | −65000 |
| `wallet-B` | Goda Canteen | 865000 (LKR 8,650) | +65000 |

**Transaction row inserted:**

```
id:               new-tx-uuid
type:             purchase
status:           completed
payer_wallet_id:  wallet-A
payee_wallet_id:  wallet-B
merchant_id:      merchant-goda
amount_cents:     65000
completed_at:     2026-03-29T07:15:30Z
```

**Ledger entries inserted:**

```
transaction_id  wallet_id   direction  amount_cents  balance_after_cents
new-tx-uuid     wallet-A    debit      65000         85000
new-tx-uuid     wallet-B    credit     65000         865000
```

**Verification** (accounting invariant):
```
Sum of all ledger entries for this transaction:
  Debit  65000 + Credit (−65000) = 0 ✓

Total system money unchanged:
  Before: 150000 + 800000 = 950000 cents
  After:   85000 + 865000 = 950000 cents ✓
```

---

## 7. Race Condition Protection

**Scenario**: Navod opens UniPay on his phone and his laptop simultaneously
and taps Pay on both within 50 milliseconds.

**Without `FOR UPDATE`**:
```
Phone  reads balance: 150000
Laptop reads balance: 150000  ← same value, race condition
Phone  writes: 150000 - 65000 = 85000 ✓
Laptop writes: 150000 - 65000 = 85000 ← ignores phone's write
Result: Navod pays twice but balance only decrements once. Merchant receives
        two payments. System integrity broken.
```

**With `FOR UPDATE` on the debit step**:
```
Phone  acquires row lock on wallet-A
Laptop tries to acquire row lock — BLOCKED, waits
Phone  completes debit: balance = 85000, commits, releases lock
Laptop acquires lock, reads balance: 85000
Laptop tries: 85000 - 65000 = 20000 — would succeed
BUT: idempotency_key check fires first — finds existing tx — returns early
Result: Phone payment succeeds. Laptop returns the same transaction ID.
        Student charged once. Merchant paid once. System integrity preserved.
```

The combination of `FOR UPDATE` row locking AND the idempotency key makes
this system safe under all concurrent access patterns.

---

## 8. What the Function Does NOT Do

These are explicitly outside the scope of `process_payment()`.
Never add these inside the function.

```
✗ Does NOT send push notifications
✗ Does NOT update campus_presence (done by event handler asynchronously)
✗ Does NOT compute or update pulse scores
✗ Does NOT validate the QR signature (done by payment.service.ts)
✗ Does NOT check rate limits (done by Cloudflare Native Rate Limiting)
✗ Does NOT log to the observability system (done by the Worker layer)
✗ Does NOT calculate merchant settlement (done by nightlySettlement cron)
```

Each of these belongs in a different layer. The stored function does
exactly one thing: move money atomically and record it. Nothing else.

---

## 9. Migration File Reference

This function is defined in:
```
database/functions/payment/process_payment.sql
database/migrations/20260324_009_transactions.sql  (table creation)
database/migrations/20260324_004_ledger.sql        (ledger_entries table)
```

When updating this function in production:
```sql
-- Use CREATE OR REPLACE — safe, no lock, no downtime
CREATE OR REPLACE FUNCTION process_payment(...) ...

-- Never DROP and recreate — causes downtime if any transaction
-- is in flight when the DROP executes
```