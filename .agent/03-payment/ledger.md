# UniPay — Double-Entry Ledger

> **AI Instruction**: This file defines the accounting layer of UniPay.
> Every balance change in the system must produce ledger entries. Never
> modify wallet balances without a corresponding ledger entry. Never
> delete or update a ledger entry after it is written. The ledger is the
> ground truth of the system — if the ledger and the wallet balance
> disagree, the ledger wins.

---

## 1. Why Double-Entry Accounting

Single-entry accounting records one number per event:
```
"Navod paid 650 LKR" → transactions table row
```

This tells you what happened but cannot prove the system has not lost
or created money. If a bug debits a student without crediting the merchant,
the transaction row exists but the money has vanished.

Double-entry accounting records two numbers per event — one debit and one
credit of equal value:
```
"Navod paid 650 LKR"
  → ledger_entry: wallet-A  DEBIT  65000 cents
  → ledger_entry: wallet-B  CREDIT 65000 cents
```

The fundamental invariant: **the sum of all ledger entries always equals
zero**. A debit of X is always paired with a credit of X. Money cannot
appear or disappear — it can only move between wallets.

This is how every bank, payment processor, and financial institution in
the world accounts for money. It is not optional for a FinTech system.

---

## 2. Core Concepts

### Debit and Credit
In UniPay's ledger, the terms are defined strictly:

```
DEBIT  = money leaving a wallet  (balance decreases)
CREDIT = money entering a wallet (balance increases)
```

This is the standard accounting definition. Do not conflate with
everyday usage ("debit card", "credit to your account") — those are
banking UX terms. In the ledger, debit always means decrease.

### The Zero-Sum Invariant
For every transaction, the sum of all its ledger entries must equal zero:

```sql
SELECT SUM(
  CASE direction
    WHEN 'debit'  THEN -amount_cents
    WHEN 'credit' THEN  amount_cents
  END
) AS net
FROM ledger_entries
WHERE transaction_id = '<any-transaction-uuid>';

-- Result must always be: 0
```

If this query returns anything other than zero for any transaction,
there is a bug in the system. This query is the integrity check.

### Balance Reconstruction
Any wallet's balance at any point in time can be reconstructed from
the ledger alone, without ever reading `wallets.balance_cents`:

```sql
SELECT SUM(
  CASE direction
    WHEN 'credit' THEN  amount_cents
    WHEN 'debit'  THEN -amount_cents
  END
) AS reconstructed_balance
FROM ledger_entries
WHERE wallet_id = '<wallet-uuid>'
  AND created_at <= '<point-in-time>';
```

This means `wallets.balance_cents` is a denormalised cache of the ledger
total — kept for fast reads at payment time, but the ledger is always
the authority. If they ever disagree, run the reconciliation query
in Section 7 to identify which transaction caused the discrepancy.

---

## 3. The `ledger_entries` Table

```sql
CREATE TABLE ledger_entries (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Link to the transaction that caused this entry
  transaction_id      UUID          NOT NULL
                      REFERENCES transactions(id) ON DELETE RESTRICT,

  -- Which wallet this entry affects
  wallet_id           UUID          NOT NULL
                      REFERENCES wallets(id) ON DELETE RESTRICT,

  -- Direction of money flow
  direction           ledger_direction NOT NULL,  -- 'debit' | 'credit'

  -- Amount in cents — always positive
  -- The direction field carries the sign
  amount_cents        BIGINT        NOT NULL CHECK (amount_cents > 0),

  -- Wallet balance immediately after this entry was applied
  -- Snapshot at write time — used for statement generation and audit
  balance_after_cents BIGINT        NOT NULL CHECK (balance_after_cents >= 0),

  -- Timestamp — stored in UTC, displayed in Asia/Colombo
  created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  -- Immutability constraint: no updates allowed
  -- Enforced by the application layer and by the absence of any
  -- UPDATE privilege on this table for the application DB user
  CONSTRAINT chk_amount_positive CHECK (amount_cents > 0)
);
```

### Indexes

```sql
-- Primary lookup: all entries for a wallet (wallet statement)
CREATE INDEX idx_ledger_wallet_id
  ON ledger_entries (wallet_id, created_at DESC);

-- Secondary lookup: all entries for a transaction (audit trail)
CREATE INDEX idx_ledger_transaction_id
  ON ledger_entries (transaction_id);

-- Reconciliation query support
CREATE INDEX idx_ledger_direction
  ON ledger_entries (wallet_id, direction, created_at DESC);
```

### Immutability
`ON DELETE RESTRICT` on both foreign keys means:
- A transaction cannot be deleted while it has ledger entries
- A wallet cannot be deleted while it has ledger entries

Neither should ever be deleted in production. The `RESTRICT` is a
safety net against accidental cascades, not an intended workflow.

---

## 4. Ledger Entry Patterns Per Transaction Type

Every transaction type produces a specific ledger pattern.
These patterns are written inside `process_payment()` and the
relevant cron functions — never in the Worker application layer.

### 4.1 Purchase / Preorder
Student pays merchant at point of sale or in advance.

```
Transaction type: 'purchase' or 'preorder'

Entries:
  wallet_id = student_wallet    direction = 'debit'   amount = X
  wallet_id = merchant_wallet   direction = 'credit'  amount = X

Net: -X + X = 0 ✓
```

### 4.2 Bank Topup (VAN)
Parent transfers money via bank. UniPay credits the student wallet.
The corresponding debit is against the system wallet — representing
money entering the Master Trust from the external bank.

```
Transaction type: 'bank_topup'

Entries:
  wallet_id = system_wallet     direction = 'debit'   amount = X
  wallet_id = student_wallet    direction = 'credit'  amount = X

Net: -X + X = 0 ✓

Interpretation: money flowed from the external world (represented by
the system wallet) into a student wallet. The system wallet's balance
represents total external money in the Master Trust.
```

### 4.3 Merchant Settlement
Nightly sweep of merchant balance to their physical bank account.
The debit hits the merchant wallet. The credit hits the system wallet —
representing money leaving the Master Trust to the real bank.

```
Transaction type: 'merchant_settlement'

Entries:
  wallet_id = merchant_wallet   direction = 'debit'   amount = X
  wallet_id = system_wallet     direction = 'credit'  amount = X

Net: -X + X = 0 ✓

Interpretation: money flowed from the merchant wallet back into the
external world (represented by the system wallet credit). The physical
bank transfer happens in parallel via the bank's settlement API.
```

### 4.4 Refund
Merchant initiates a reversal of a previous purchase.
Exact mirror image of the original purchase entries.

```
Transaction type: 'refund'
References: original_transaction_id (stored on the refund transaction row)

Entries:
  wallet_id = merchant_wallet   direction = 'debit'   amount = X
  wallet_id = student_wallet    direction = 'credit'  amount = X

Net: -X + X = 0 ✓

Constraint: refund amount_cents must be <= original purchase amount_cents.
            Partial refunds are allowed. Over-refunds are not.
```

### 4.5 Admin Adjustment (Credit)
Admin adds funds to any wallet (correction, goodwill credit).

```
Transaction type: 'admin_adjustment'
Requires: reason field non-null, admin role

Entries:
  wallet_id = admin_wallet      direction = 'debit'   amount = X
  wallet_id = target_wallet     direction = 'credit'  amount = X

Net: -X + X = 0 ✓
```

### 4.6 Admin Adjustment (Debit — Reclaim)
Admin reclaims balance from a closed wallet (e.g., graduated student
with remaining balance).

```
Transaction type: 'admin_adjustment'
Precondition: target wallet status must be 'closed'

Entries:
  wallet_id = target_wallet     direction = 'debit'   amount = X
  wallet_id = admin_wallet      direction = 'credit'  amount = X

Net: -X + X = 0 ✓
```

---

## 5. The System Wallet

The system wallet is a special wallet owned by the `admin` role user.
It represents the boundary between UniPay's closed loop and the
external banking world.

```
When money enters UniPay  → system wallet is DEBITED
When money leaves UniPay  → system wallet is CREDITED
```

At any point in time:
```
system_wallet.balance_cents should equal ZERO

Because:
  Every VAN topup debits the system wallet
  Every settlement credits the system wallet
  In a perfectly balanced system these cancel out

If system_wallet.balance_cents != 0, there is an unreconciled
discrepancy between UniPay's ledger and the Master Trust account.
This triggers an admin alert.
```

---

## 6. Generating a Wallet Statement

The ledger enables a complete, chronological statement for any wallet
at any time. This powers the student transaction history and the
merchant settlement report.

```sql
-- Full statement for a wallet, most recent first
SELECT
  le.created_at                                    AS timestamp,
  t.type                                           AS transaction_type,
  le.direction,
  le.amount_cents,
  le.balance_after_cents,
  -- Display amount with sign
  CASE le.direction
    WHEN 'debit'  THEN -le.amount_cents
    WHEN 'credit' THEN  le.amount_cents
  END                                              AS signed_amount_cents,
  -- Counterparty name for display
  CASE t.type
    WHEN 'purchase'   THEN m.business_name
    WHEN 'bank_topup' THEN 'Bank Transfer (VAN)'
    WHEN 'refund'     THEN m.business_name
    ELSE 'System'
  END                                              AS counterparty_name,
  t.receipt_payload                                AS receipt
FROM ledger_entries le
JOIN transactions t  ON t.id  = le.transaction_id
LEFT JOIN merchants m ON m.id = t.merchant_id
WHERE le.wallet_id = $1
ORDER BY le.created_at DESC
LIMIT 50 OFFSET $2;
```

This query is defined as the view `v_wallet_statement` in
`database/views/wallet_balance_view.sql`.

---

## 7. Reconciliation Queries

Run these queries to verify system integrity. The admin dashboard
runs them nightly and alerts if any return non-zero results.

### 7.1 Transaction Zero-Sum Check
Every transaction's ledger entries must net to zero.

```sql
SELECT
  transaction_id,
  SUM(
    CASE direction
      WHEN 'debit'  THEN -amount_cents
      WHEN 'credit' THEN  amount_cents
    END
  ) AS net
FROM ledger_entries
GROUP BY transaction_id
HAVING SUM(
  CASE direction
    WHEN 'debit'  THEN -amount_cents
    WHEN 'credit' THEN  amount_cents
  END
) != 0;

-- Expected result: zero rows
-- Non-zero rows = broken transactions requiring manual investigation
```

### 7.2 Wallet Balance Integrity Check
Each wallet's `balance_cents` must match the ledger sum.

```sql
SELECT
  w.id                    AS wallet_id,
  w.balance_cents         AS cached_balance,
  COALESCE(SUM(
    CASE le.direction
      WHEN 'credit' THEN  le.amount_cents
      WHEN 'debit'  THEN -le.amount_cents
    END
  ), 0)                   AS ledger_balance,
  w.balance_cents - COALESCE(SUM(
    CASE le.direction
      WHEN 'credit' THEN  le.amount_cents
      WHEN 'debit'  THEN -le.amount_cents
    END
  ), 0)                   AS discrepancy_cents
FROM wallets w
LEFT JOIN ledger_entries le ON le.wallet_id = w.id
GROUP BY w.id, w.balance_cents
HAVING w.balance_cents != COALESCE(SUM(
  CASE le.direction
    WHEN 'credit' THEN  le.amount_cents
    WHEN 'debit'  THEN -le.amount_cents
  END
), 0);

-- Expected result: zero rows
-- Non-zero rows = wallet cache out of sync with ledger
```

### 7.3 Master Trust Integrity Check
Total student + merchant wallet balances must equal the absolute
value of the system wallet's ledger balance.

```sql
WITH
  system_balance AS (
    SELECT COALESCE(SUM(
      CASE direction
        WHEN 'credit' THEN  amount_cents
        WHEN 'debit'  THEN -amount_cents
      END
    ), 0) AS balance
    FROM ledger_entries
    WHERE wallet_id = (
      SELECT id FROM wallets WHERE type = 'system' LIMIT 1
    )
  ),
  user_balances AS (
    SELECT COALESCE(SUM(balance_cents), 0) AS total
    FROM wallets
    WHERE type IN ('personal', 'merchant')
    AND status != 'closed'
  )
SELECT
  user_balances.total         AS total_user_balances,
  ABS(system_balance.balance) AS master_trust_representation,
  user_balances.total +
    system_balance.balance    AS discrepancy
FROM user_balances, system_balance;

-- Expected discrepancy: 0
-- Non-zero = Master Trust and ledger are out of sync
-- This is a critical alert — investigate immediately
```

### 7.4 Orphaned Ledger Entries
Ledger entries with no matching transaction (referential integrity
should prevent this, but check anyway after any migration).

```sql
SELECT le.id, le.transaction_id, le.created_at
FROM ledger_entries le
LEFT JOIN transactions t ON t.id = le.transaction_id
WHERE t.id IS NULL;

-- Expected result: zero rows
```

---

## 8. The Immutability Guarantee

Ledger entries are written once and never modified. This is enforced
at three levels:

**Level 1 — Application layer**: No UPDATE or DELETE SQL is written
anywhere in the Worker codebase for the `ledger_entries` table.

**Level 2 — Database user privileges**: The application's PostgreSQL
role has INSERT and SELECT on `ledger_entries` but NOT UPDATE or DELETE.

```sql
-- Run once during database setup
GRANT SELECT, INSERT ON ledger_entries TO unipay_app;
-- Deliberately NO UPDATE, NO DELETE
```

**Level 3 — Trigger (safety net)**:

```sql
CREATE OR REPLACE FUNCTION prevent_ledger_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'UNIPAY_ERR_LEDGER_IMMUTABLE'
    USING HINT = 'Ledger entries cannot be modified after creation';
END;
$$;

CREATE TRIGGER trg_ledger_no_update
  BEFORE UPDATE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION prevent_ledger_mutation();

CREATE TRIGGER trg_ledger_no_delete
  BEFORE DELETE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION prevent_ledger_mutation();
```

If any code path attempts to update or delete a ledger entry, it hits
all three layers. The trigger is the last line of defence — it will
catch even direct psql terminal commands run by a developer in production.

---

## 9. Reversals — Never Edit, Always Append

When a refund is needed, a new transaction and new ledger entries are
created. The original entries are never touched.

```
Original purchase (2026-03-29 12:15):
  tx-001  wallet-A  DEBIT   65000   balance_after: 85000
  tx-001  wallet-B  CREDIT  65000   balance_after: 865000

Refund (2026-03-29 14:30):
  tx-002  wallet-B  DEBIT   65000   balance_after: 800000
  tx-002  wallet-A  CREDIT  65000   balance_after: 150000

Audit trail is complete:
  12:15 — student paid merchant 650 LKR
  14:30 — merchant refunded student 650 LKR
  Net position: unchanged, fully traceable
```

The `transactions` table has a `reference_transaction_id` column for
refunds to point back to the original purchase. This enables the Worker
to validate that the refund amount does not exceed the original.

---

## 10. Related Files

- `03-payment/process-payment-fn.md` — where ledger entries are written
- `03-payment/overview.md` — financial integrity rules
- `03-payment/settlement.md` — nightly settlement ledger pattern
- `database/schemas/ledger.sql` — table definitions
- `database/views/wallet_balance_view.sql` — v_wallet_statement view
- `07-admin/system-dashboard.md` — reconciliation monitoring