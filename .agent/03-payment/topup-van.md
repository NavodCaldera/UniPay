# UniPay — VAN Top-Up System

> **AI Instruction**: This file defines the complete Virtual Account Number
> (VAN) funding mechanism. This is the ONLY way money enters UniPay. There
> is no card payment, no PayHere, no cash deposit. Every design decision
> here exists to protect the integrity of the Master Trust account and
> to ensure parents can top up with zero technical knowledge. Do not
> suggest alternative funding mechanisms.

---

## 1. What a VAN Is

A Virtual Account Number (VAN) is a real bank account number issued by the
partner bank (HNB or Seylan) under the Master Trust structure. It looks and
behaves exactly like a standard Sri Lankan bank account number to anyone
making a transfer.

From the parent's perspective:
```
"Transfer LKR 5,000 to account number 0789-4521-0034-001"
```

From UniPay's perspective:
```
That account number is mapped to Navod's student wallet.
When money arrives, credit Navod's balance_cents by 500000.
```

The parent needs no app, no registration, no digital wallet, no knowledge
of UniPay. They use their existing internet banking exactly as they would
to pay a utility bill. This is the strongest possible adoption mechanism
for the parent segment in the Sri Lankan market.

---

## 2. JIT (Just-In-Time) Allocation

VANs are not assigned to students at registration. They are allocated from
a pre-provisioned pool only when a student explicitly requests one.

### Why JIT and Not Pre-Assignment

```
University enrollment: 5,000 students
Students who actually top up via bank: estimated 60% = 3,000

If pre-assigned: 5,000 VANs provisioned, 2,000 sitting idle
Each VAN costs the bank a monthly maintenance fee
5,000 × LKR 50/month = LKR 250,000/month wasted

If JIT-allocated: 3,000 VANs provisioned on demand
3,000 × LKR 50/month = LKR 150,000/month
Saving: LKR 100,000/month = LKR 1,200,000/year
```

JIT allocation saves approximately LKR 1.2 million per year per campus
compared to pre-assignment, with zero functional difference for students.

### The Allocation Flow

```
Student taps "Top Up via Bank" for the first time
         │
         ▼
Worker checks: does this student have a VAN assigned?
SELECT assigned_to FROM vans WHERE assigned_to = $student_id
         │
    ┌────┴────┐
    │         │
  YES         NO
    │         │
    │         ▼
    │   Pull one VAN from the available pool
    │   SELECT id, van_number FROM vans
    │   WHERE status = 'available'
    │   LIMIT 1
    │   FOR UPDATE SKIP LOCKED   ← critical: prevents race condition
    │         │
    │         ▼
    │   UPDATE vans SET
    │     status      = 'assigned',
    │     assigned_to = $student_id,
    │     assigned_at = NOW()
    │   WHERE id = $van_id
    │         │
    └────┬────┘
         │
         ▼
Return VAN number to student
Display: "Your top-up account number is 0789-4521-0034-001"
         "Share this with anyone who wants to send you money"
```

### `FOR UPDATE SKIP LOCKED` — Why It Is Critical

Without this clause, two students tapping "Top Up via Bank" simultaneously
could both read the same available VAN, creating a duplicate assignment.
`FOR UPDATE SKIP LOCKED` means:

- Each Worker request locks one VAN row exclusively
- Any other concurrent request skips that locked row and takes the next one
- Two students can never be assigned the same VAN

This is the correct PostgreSQL pattern for pool-based resource allocation.

---

## 3. The VAN Lifecycle

A VAN moves through four states over its lifetime. These states are defined
in the `van_status` enum in `database/schemas/enums.sql`.

```
                    ┌───────────┐
                    │ available │  In the pool, unassigned
                    └─────┬─────┘
                          │ Student taps "Top Up via Bank"
                          │ JIT allocation
                          ▼
                    ┌───────────┐
                    │ assigned  │  Live, accepting deposits
                    └─────┬─────┘
                          │ 6 months after expected_grad_year
                          │ vanReclaim.ts cron fires
                          ▼
                   ┌─────────────┐
                   │ quarantined │  Bounces all incoming deposits
                   └──────┬──────┘
                          │ 12 months in quarantine
                          │ (18 months after expected_grad_year total)
                          ▼
              ┌──────────────────────┐
              │ eligible_for_recycle │  Safe to reassign to new student
              └──────────────────────┘
                          │ Admin runs recycle operation
                          ▼
                    ┌───────────┐
                    │ available │  Back in the pool
                    └───────────┘
```

### State Definitions

| State | `vans.status` | Deposits | Description |
|---|---|---|---|
| Available | `available` | N/A | In the pool, no student assigned |
| Assigned | `assigned` | Accepted and credited | Live, linked to a student |
| Quarantined | `quarantined` | Bounced to sender | 6 months post-graduation |
| Eligible | `eligible_for_recycle` | Still bounced | 18 months post-graduation |

### The Quarantine Purpose

Without quarantine, this scenario occurs:

```
2024: Navod graduates. VAN 0789-4521-0034-001 is reclaimed.
2024: VAN reassigned to new student Amara.
2025: Navod's parent (who saved the VAN number) transfers LKR 5,000
      thinking they are topping up Navod's wallet.
      Instead, Amara receives LKR 5,000 for free.
      Navod's parent loses LKR 5,000 with no recourse.
```

The 6-month quarantine period after graduation ensures enough time passes
that no parent would still be sending money to an old VAN. The subsequent
12-month bouncing period provides an additional safety margin before the
VAN is recycled to a new student.

**Total protection window: 18 months after expected graduation year.**

---

## 4. The `vans` Table

```sql
CREATE TABLE vans (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- The actual bank account number string issued by HNB/Seylan
  van_number            TEXT        NOT NULL UNIQUE,

  -- Current lifecycle state
  status                van_status  NOT NULL DEFAULT 'available',

  -- Student currently assigned to this VAN (NULL when available)
  assigned_to           UUID        REFERENCES users(id) ON DELETE SET NULL,
  assigned_at           TIMESTAMPTZ,

  -- Graduation tracking for quarantine timing
  -- Copied from users.expected_grad_year at assignment time
  -- Stored here so changes to users.expected_grad_year do not
  -- accidentally alter the quarantine schedule for active VANs
  grad_year_snapshot    SMALLINT,

  -- Computed lifecycle timestamps (stored for cron job efficiency)
  -- Set when the student graduates / VAN is deactivated
  deactivated_at        TIMESTAMPTZ,

  -- quarantine_starts_at  = deactivated_at + 6 months
  -- recycle_eligible_at   = deactivated_at + 18 months
  -- Stored as computed columns — never manually set
  quarantine_starts_at  TIMESTAMPTZ GENERATED ALWAYS AS (
    deactivated_at + INTERVAL '6 months'
  ) STORED,

  recycle_eligible_at   TIMESTAMPTZ GENERATED ALWAYS AS (
    deactivated_at + INTERVAL '18 months'
  ) STORED,

  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_vans_status
  ON vans (status);

CREATE INDEX idx_vans_assigned_to
  ON vans (assigned_to)
  WHERE assigned_to IS NOT NULL;

CREATE INDEX idx_vans_quarantine_check
  ON vans (quarantine_starts_at, recycle_eligible_at)
  WHERE status IN ('assigned', 'quarantined');
```

---

## 5. The Bank Webhook Flow

When a parent transfers money to a VAN, the partner bank fires an HTTP
webhook to the UniPay Worker. This is how UniPay knows money has arrived.

### Webhook Endpoint

```
POST /api/v1/webhooks/bank/topup
```

This endpoint is NOT protected by the JWT cookie middleware. It is
protected by HMAC signature verification using a shared secret agreed
with the bank. Any request without a valid signature is rejected with
403 before any business logic runs.

### Webhook Payload (from bank)

```typescript
interface BankTopupWebhook {
  event_id:        string;   // Bank's unique event ID — used for idempotency
  van_number:      string;   // The VAN that received money
  amount_lkr:      string;   // "650.00" — string from bank, convert to cents
  sender_name:     string;   // Parent's name (for student's transaction history)
  sender_bank:     string;   // e.g. "Commercial Bank"
  reference:       string;   // Bank transfer reference number
  received_at:     string;   // ISO 8601 timestamp from bank
}
```

### Webhook Processing Flow

```typescript
// worker/src/modules/payment/payment.controller.ts

payment.post('/webhooks/bank/topup', async (c) => {

  // Step 1: Verify bank HMAC signature
  const signature = c.req.header('X-Bank-Signature');
  const body      = await c.req.text(); // Raw body for signature verification
  const isValid   = await verifyBankWebhookSignature(
    body, signature, c.env.BANK_WEBHOOK_SECRET
  );
  if (!isValid) {
    return c.json({ error: 'Invalid signature' }, 403);
  }

  const payload: BankTopupWebhook = JSON.parse(body);

  // Step 2: Idempotency — bank may retry failed webhooks
  const existing = await db.query(
    'SELECT id FROM transactions WHERE bank_reference = $1',
    [payload.event_id]
  );
  if (existing.rows[0]) {
    // Already processed — acknowledge to bank so it stops retrying
    return c.json({ status: 'already_processed' }, 200);
  }

  // Step 3: Look up VAN → student wallet
  const van = await db.query(
    `SELECT v.id, v.status, v.assigned_to, w.id AS wallet_id
     FROM vans v
     JOIN wallets w ON w.user_id = v.assigned_to
     WHERE v.van_number = $1`,
    [payload.van_number]
  );

  if (!van.rows[0]) {
    // VAN not found — log for manual investigation, acknowledge to bank
    await logger.error('Unknown VAN received', { van_number: payload.van_number });
    return c.json({ status: 'van_not_found' }, 200); // 200 so bank stops retry
  }

  // Step 4: Handle quarantined VAN — bounce the deposit
  if (van.rows[0].status === 'quarantined' ||
      van.rows[0].status === 'eligible_for_recycle') {
    await BounceService.initiateReturn(payload);
    await logger.warn('Quarantined VAN deposit bounced', {
      van_number: payload.van_number,
      amount_lkr: payload.amount_lkr
    });
    return c.json({ status: 'bounced' }, 200);
  }

  // Step 5: Convert amount to cents
  // Bank sends "650.00" — convert carefully to avoid float errors
  const amountCents = Math.round(parseFloat(payload.amount_lkr) * 100);

  // Step 6: Credit student wallet via stored function
  await db.query(
    `SELECT process_bank_topup($1, $2, $3, $4)`,
    [
      van.rows[0].wallet_id,
      amountCents,
      payload.event_id,    // used as idempotency_key
      payload.reference    // bank reference stored on transaction
    ]
  );

  // Step 7: Acknowledge to bank — must return 200 or bank retries
  return c.json({ status: 'credited' }, 200);
});
```

### Webhook Idempotency

Banks retry failed webhooks — if the UniPay server is briefly unreachable,
the bank will attempt delivery again after 30 seconds, 5 minutes, and so on.

The `bank_reference` field (the bank's `event_id`) is stored on the
transaction row and checked before processing. If the webhook arrives twice,
the second delivery finds the existing transaction and returns `200` without
crediting the wallet again.

This is separate from the payment idempotency key — it uses `bank_reference`
rather than a client-generated UUID because the bank controls the identifier.

---

## 6. The `process_bank_topup()` Function

A dedicated stored function handles bank topups, separate from
`process_payment()` because the flow is different: there is no payer
wallet to debit — money enters from the system wallet (representing
the Master Trust receiving external funds).

```sql
CREATE OR REPLACE FUNCTION process_bank_topup(
  p_student_wallet_id   UUID,
  p_amount_cents        BIGINT,
  p_bank_event_id       TEXT,    -- Bank's event ID used as idempotency key
  p_bank_reference      TEXT     -- Bank transfer reference number
)
RETURNS UUID
LANGUAGE plpgsql AS $$
DECLARE
  v_system_wallet_id  UUID;
  v_transaction_id    UUID;
BEGIN

  -- Get system wallet ID
  SELECT id INTO v_system_wallet_id
  FROM wallets WHERE type = 'system' LIMIT 1;

  -- Idempotency guard using bank_reference
  SELECT id INTO v_transaction_id
  FROM transactions WHERE bank_reference = p_bank_event_id;

  IF FOUND THEN
    RETURN v_transaction_id; -- Already processed, return existing ID
  END IF;

  -- Validate amount
  IF p_amount_cents <= 0 THEN
    RAISE EXCEPTION 'UNIPAY_ERR_INVALID_TOPUP_AMOUNT'
      USING ERRCODE = 'P0010';
  END IF;

  -- Debit system wallet (money entering the Master Trust)
  UPDATE wallets
  SET balance_cents = balance_cents - p_amount_cents,
      updated_at    = NOW()
  WHERE id = v_system_wallet_id;

  -- Credit student wallet
  UPDATE wallets
  SET balance_cents = balance_cents + p_amount_cents,
      updated_at    = NOW()
  WHERE id = p_student_wallet_id;

  -- Insert transaction record
  INSERT INTO transactions (
    type,
    status,
    payer_wallet_id,
    payee_wallet_id,
    amount_cents,
    bank_reference,
    completed_at
  ) VALUES (
    'bank_topup',
    'completed',
    v_system_wallet_id,
    p_student_wallet_id,
    p_amount_cents,
    p_bank_event_id,
    NOW()
  ) RETURNING id INTO v_transaction_id;

  -- Double-entry ledger
  INSERT INTO ledger_entries
    (transaction_id, wallet_id, direction, amount_cents, balance_after_cents)
  VALUES
    (v_transaction_id, v_system_wallet_id,  'debit',
      p_amount_cents,
      (SELECT balance_cents FROM wallets WHERE id = v_system_wallet_id)),
    (v_transaction_id, p_student_wallet_id, 'credit',
      p_amount_cents,
      (SELECT balance_cents FROM wallets WHERE id = p_student_wallet_id));

  RETURN v_transaction_id;

END; $$;
```

---

## 7. The `vanReclaim.ts` Cron Job

Runs daily at 02:00 LKT. Moves assigned VANs into quarantine when
the quarantine window has passed, and quarantined VANs into
`eligible_for_recycle` when the full 18 months have elapsed.

```typescript
// worker/src/cron/vanReclaim.ts

export async function vanReclaimCron(env: Env): Promise<void> {
  const db = getDB(env);

  // Move assigned → quarantined
  // Fires when quarantine_starts_at has passed
  const quarantined = await db.query(`
    UPDATE vans
    SET status        = 'quarantined',
        deactivated_at = NOW()
    WHERE status               = 'assigned'
      AND quarantine_starts_at <= NOW()
    RETURNING id, van_number, assigned_to
  `);

  // Move quarantined → eligible_for_recycle
  // Fires when recycle_eligible_at has passed
  const eligible = await db.query(`
    UPDATE vans
    SET status = 'eligible_for_recycle'
    WHERE status              = 'quarantined'
      AND recycle_eligible_at <= NOW()
    RETURNING id, van_number
  `);

  await logger.info('VAN reclaim cron completed', {
    newly_quarantined:       quarantined.rowCount,
    newly_eligible:          eligible.rowCount,
    timestamp:               new Date().toISOString()
  });
}
```

---

## 8. The Bounce Service

When a deposit arrives on a quarantined VAN, the bank must be instructed
to return the funds to the sender. This is a bank API call, not a
UniPay ledger operation — no money entered UniPay, so no ledger entry
is created.

```typescript
// worker/src/modules/payment/bounce.service.ts

export async function initiateReturn(
  payload: BankTopupWebhook
): Promise<void> {

  // Call partner bank's return API
  const response = await fetch(env.BANK_RETURN_API_URL, {
    method: 'POST',
    headers: {
      'Content-Type':  'application/json',
      'Authorization': `Bearer ${env.BANK_API_KEY}`
    },
    body: JSON.stringify({
      original_reference: payload.reference,
      van_number:         payload.van_number,
      amount_lkr:         payload.amount_lkr,
      return_reason:      'ACCOUNT_CLOSED',
      return_note:        'This account is no longer active. Please contact the account holder.'
    })
  });

  if (!response.ok) {
    // Log for manual follow-up — cannot leave sender without their money
    await logger.error('BOUNCE_FAILED — manual intervention required', {
      van_number:  payload.van_number,
      amount_lkr:  payload.amount_lkr,
      reference:   payload.reference,
      bank_status: response.status
    });

    // Alert admin dashboard
    await notifyAdmin({
      type:    'bounce_failure',
      message: `Failed to bounce deposit of LKR ${payload.amount_lkr} on quarantined VAN ${payload.van_number}`,
      data:    payload
    });
  }
}
```

---

## 9. VAN Pool Management

The admin dashboard provides a real-time view of VAN pool health.

```sql
-- Pool status summary for admin dashboard
SELECT
  status,
  COUNT(*)                               AS count,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM vans
GROUP BY status
ORDER BY
  CASE status
    WHEN 'available'           THEN 1
    WHEN 'assigned'            THEN 2
    WHEN 'quarantined'         THEN 3
    WHEN 'eligible_for_recycle' THEN 4
  END;
```

Expected healthy output:
```
status                 count    pct
available              800      16%
assigned               3000     60%
quarantined            800      16%
eligible_for_recycle   400       8%
```

**Alert threshold**: If `available` count drops below 200, the admin
dashboard shows a red warning and triggers an email to request
additional VANs from the partner bank.

---

## 10. Security Considerations

**The webhook endpoint is a financial attack surface.** Any party that
can POST to `/api/v1/webhooks/bank/topup` with a fabricated payload
could credit any wallet with arbitrary amounts.

Three defences are in place:

```
1. HMAC-SHA256 signature on every webhook request
   Secret shared out-of-band with the bank
   Any unsigned or incorrectly signed request → 403, no processing

2. The bank's IP address is allowlisted at the Cloudflare firewall level
   Requests from any other IP never reach the Worker

3. The event_id idempotency check prevents replay attacks
   Even if an attacker captures a valid signed payload and replays it,
   the bank_reference check catches it before crediting the wallet
```

All three must be in place. Any single one alone is insufficient.

---

## 11. Related Files

- `03-payment/ledger.md` — how bank_topup entries appear in the ledger
- `03-payment/overview.md` — why VAN is the only funding mechanism
- `03-payment/settlement.md` — the outbound money flow
- `08-worker/cron-jobs.md` — vanReclaim.ts schedule and monitoring
- `07-admin/van-lifecycle.md` — admin dashboard for VAN pool management
- `database/schemas/vans.sql` — full table definition
- `database/functions/payment/process_bank_topup.sql` — stored function