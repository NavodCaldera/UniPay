# UniPay — Stored Functions Reference

> **AI Instruction**: This file is the index of every stored PostgreSQL
> function. Full SQL implementations live in database/functions/. When
> writing Worker code that calls a database function, use the exact
> parameter names, types, and order documented here. Never replicate
> stored function logic in TypeScript — the database is the authority
> on all atomic operations.

---

## Why Stored Functions

Stored functions exist for operations that must be atomic — where
multiple SQL statements must either all succeed or all fail together.

```
Rule: If an operation touches more than one table in a way that
      would leave the database in an inconsistent state if interrupted,
      it belongs in a stored function.

Rule: The Worker never issues raw UPDATE statements against
      wallets.balance_cents, transactions, or ledger_entries.
      These are written only by stored functions.
```

---

## Payment Functions

### `process_payment()`

The most critical function in the system. Handles all student-to-merchant
payments (purchases and preorders) atomically.

```
File:     database/functions/payment/process_payment.sql
Returns:  UUID (new transaction id)
Called by: payment.repository.ts → callProcessPayment()
```

```sql
process_payment(
  p_payer_wallet_id   UUID,             -- Student wallet
  p_payee_wallet_id   UUID,             -- Merchant wallet
  p_merchant_id       UUID,             -- Merchant record
  p_amount_cents      BIGINT,           -- Integer cents only
  p_transaction_type  transaction_type, -- 'purchase' | 'preorder'
  p_receipt_payload   JSONB,            -- SKU line items (nullable)
  p_idempotency_key   UUID,             -- Client-generated UUID v4
  p_payload_hash      CHAR(64)          -- SHA-256 of request payload
) RETURNS UUID
```

**Operations in order (all atomic):**
1. Idempotency guard — returns existing ID if key seen before
2. Forgery check — payload hash must match stored hash
3. Input validation — amount > 0, payer ≠ payee, both wallets active
4. Debit payer with `FOR UPDATE` row lock
5. Credit payee
6. Insert transaction row
7. Insert two ledger_entry rows

**Exceptions raised:**

| Code | Meaning | HTTP response |
|---|---|---|
| `UNIPAY_ERR_IDEMPOTENCY_FORGERY` | Hash mismatch on retry | 422 |
| `UNIPAY_ERR_INVALID_AMOUNT` | amount_cents ≤ 0 | 400 |
| `UNIPAY_ERR_SELF_PAYMENT` | Payer = payee | 400 |
| `UNIPAY_ERR_PAYER_WALLET_INVALID` | Wallet missing or not active | 403 |
| `UNIPAY_ERR_PAYEE_WALLET_INVALID` | Wallet missing or not active | 403 |
| `check_balance_non_negative` (PG) | Insufficient funds | 402 |

Full documented implementation: `03-payment/process-payment-fn.md`

---

### `process_bank_topup()`

Credits a student wallet when a bank transfer arrives via the VAN
webhook. The system wallet is debited to represent money entering
the Master Trust.

```
File:     database/functions/payment/process_bank_topup.sql
Returns:  UUID (new transaction id)
Called by: payment.controller.ts → webhook handler
```

```sql
process_bank_topup(
  p_student_wallet_id  UUID,    -- Student wallet to credit
  p_amount_cents       BIGINT,  -- Integer cents
  p_bank_event_id      TEXT,    -- Bank's unique event ID (idempotency key)
  p_bank_reference     TEXT     -- Bank transfer reference number
) RETURNS UUID
```

**Operations in order:**
1. Idempotency guard using `bank_reference`
2. Validate amount > 0
3. Debit system wallet
4. Credit student wallet
5. Insert `bank_topup` transaction row
6. Insert two ledger_entry rows

---

### `process_settlement()`

Zeros a merchant wallet and records the nightly settlement. The system
wallet is credited to represent money leaving the Master Trust.

```
File:     database/functions/payment/process_settlement.sql
Returns:  UUID (new transaction id)
Called by: nightlySettlement.ts cron job
```

```sql
process_settlement(
  p_merchant_wallet_id  UUID,    -- Merchant wallet to zero
  p_amount_cents        BIGINT,  -- Must match wallet.balance_cents exactly
  p_bank_reference      TEXT,    -- Bank's transfer reference
  p_settlement_date     DATE     -- Trading date being settled
) RETURNS UUID
```

**Exceptions raised:**

| Code | Meaning |
|---|---|
| `UNIPAY_ERR_SETTLEMENT_AMOUNT_MISMATCH` | p_amount_cents ≠ current wallet balance |

---

## Attendance Functions

### `generate_attendance_code()`

Generates a unique 5-character code from the ambiguity-free pool.
Loops until a unique active code is found.

```
File:     database/functions/attendance/generate_attendance_code.sql
Returns:  CHAR(5)
Called by: create_sheet()
```

```sql
generate_attendance_code() RETURNS CHAR(5)
```

**Character pool:**
```
ABCDEFGHJKLMNPQRTUVWXYZabcdefghjkmnpqrtuvwxyz23456789
Excluded: 0 O 1 l I 5 S  (visually ambiguous on projector screens)
Pool size: 55 characters → 55^5 = 503,284,375 combinations
```

---

### `create_sheet()`

Creates an attendance sheet. Any authenticated user can call this.
No role restrictions.

```
File:     database/functions/attendance/create_sheet.sql
Returns:  attendance_sheets row
Called by: attendance.repository.ts
```

```sql
create_sheet(
  p_created_by        UUID,    -- Any authenticated user UUID
  p_module_code       TEXT,    -- e.g. "CS3012"
  p_module_name       TEXT,    -- e.g. "Machine Learning"
  p_sheet_date        DATE,    -- Usually CURRENT_DATE
  p_closing_time      TIME,    -- Scheduled lecture end time
  p_duration_seconds  INT      -- Total seconds (minutes × 60 + seconds)
) RETURNS attendance_sheets
```

**Validations:**
- duration_seconds must be BETWEEN 30 AND 3600
- Trims whitespace from module_code (uppercased) and module_name
- Calls `generate_attendance_code()` internally

---

### `mark_attendance()`

Processes a student's attendance code submission. Enforces the
university_index gate, validates the code, prevents duplicates,
and atomically increments the sheet's `total_marked` counter.

```
File:     database/functions/attendance/mark_attendance.sql
Returns:  JSONB with success/failure details
Called by: attendance.repository.ts
```

```sql
mark_attendance(
  p_user_id      UUID,          -- Must have university_index filled
  p_code         CHAR(5),       -- The code entered by the student
  p_ip           INET,          -- Submitting device IP address
  p_network_type network_type   -- Classified by Worker before calling
) RETURNS JSONB
```

**Return shape (success):**
```json
{
  "success": true,
  "module_code": "CS3012",
  "module_name": "Machine Learning",
  "marked_at": "2026-03-29T07:15:30Z",
  "is_flagged": false
}
```

**Return shape (failure):**
```json
{
  "success": false,
  "reason": "wrong_code | expired | duplicate | no_index_number",
  "message": "Human-readable message for the student"
}
```

**Gate checks in order:**
1. User has `university_index` — else returns `no_index_number`
2. Code exists in `attendance_sheets` — else returns `wrong_code`
3. Session is active and not expired — else returns `expired`
4. No existing record for this user+sheet — else returns `duplicate`
5. Classifies network, inserts record, increments counter, logs attempt

---

### `close_sheet()`

Closes an attendance sheet. Called by the timer expiry cron or
when the creator clicks Close Early. Sets `export_ready = TRUE`
which triggers the Excel export.

```
File:     database/functions/attendance/close_sheet.sql
Returns:  JSONB with summary
Called by: expireSheets.ts cron, attendance.controller.ts
```

```sql
close_sheet(
  p_sheet_id    UUID,   -- Sheet to close
  p_closed_by   UUID,   -- Creator UUID or system UUID for cron
  p_reason      TEXT    -- 'timer_expired' | 'manual_close'
) RETURNS JSONB
```

**Rules:**
- `manual_close` is only allowed if `p_closed_by = sheet.created_by`
- `timer_expired` is allowed from any caller (cron uses system UUID)
- Sets `status = 'expired'` for timer expiry, `status = 'closed'` for manual
- Sets `export_ready = TRUE` — triggers the Excel export event handler

---

### `manual_add_attendance()`

Adds a student to a closed sheet. Only the sheet creator can call this.
Looks up the target student by `university_index`.

```
File:     database/functions/attendance/manual_add_attendance.sql
Returns:  JSONB with result
Called by: attendance.controller.ts
```

```sql
manual_add_attendance(
  p_sheet_id         UUID,   -- Must be closed or expired (not active)
  p_requester_id     UUID,   -- Must match sheet.created_by
  p_target_index     TEXT,   -- university_index of student to add
  p_reason           TEXT    -- Mandatory reason (e.g. "Phone battery died")
) RETURNS JSONB
```

---

### `get_sheet_export()`

Returns all present records for a sheet, sorted by university_index.
Used by the Excel export generator in `attendance.export.ts`.

```
File:     database/functions/attendance/get_sheet_export.sql
Returns:  TABLE of export rows
Called by: attendance.export.ts after sheet closes
```

```sql
get_sheet_export(
  p_sheet_id UUID
) RETURNS TABLE (
  university_index   TEXT,
  full_name          TEXT,
  submitted_at       TIMESTAMPTZ,
  network_type       network_type,
  is_flagged         BOOLEAN,
  manual_add         BOOLEAN
)
```

---

## Analytics Functions

### `compute_traffic_score()`

Computes the Campus Pulse score for a given rush period.
Score formula: `T = round(P × 100)`
Where `P = min(confirmed_present / historical_avg_present, 1.0)`

```
File:     database/functions/analytics/compute_traffic_score.sql
Returns:  INTEGER (0–100)
Called by: refreshTrafficScore.ts cron (at 06:00, 12:00, 18:00 LKT)
```

```sql
compute_traffic_score(
  p_rush_period  rush_period,
  p_date         DATE DEFAULT CURRENT_DATE
) RETURNS INTEGER
```

**Process:**
1. Count confirmed_present students for `p_rush_period` today
2. Calculate historical_avg_present from same period over last 4 weeks
3. Compute P = min(today / avg, 1.0) — defaults to 0.5 if no history
4. Write score to `demand_forecasts` table (upsert)
5. Return the score — caller writes it to KV cache

Full equation documentation: `05-merchant/traffic-score-equation.md`

---

## Utility Functions

### `set_updated_at()`

Trigger function that automatically updates `updated_at` to `NOW()`
on every UPDATE. Applied to: `users`, `wallets`, `merchants`, `skus`,
`attendance_sheets`.

```
File:     database/functions/shared/set_updated_at.sql
```

```sql
-- Applied as:
CREATE TRIGGER trg_{table}_updated_at
  BEFORE UPDATE ON {table}
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

---

### `prevent_ledger_mutation()`

Trigger function that raises an exception if any code attempts to
UPDATE or DELETE a `ledger_entries` row. The final line of defence
for ledger immutability.

```
File:     database/functions/shared/prevent_ledger_mutation.sql
```

```sql
-- Applied as:
CREATE TRIGGER trg_ledger_no_update
  BEFORE UPDATE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION prevent_ledger_mutation();

CREATE TRIGGER trg_ledger_no_delete
  BEFORE DELETE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION prevent_ledger_mutation();
```

Exception raised: `UNIPAY_ERR_LEDGER_IMMUTABLE`

---

## Function Error Code Reference

All custom exception codes raised by stored functions:

| Error code | Function | HTTP status | Meaning |
|---|---|---|---|
| `UNIPAY_ERR_IDEMPOTENCY_FORGERY` | `process_payment` | 422 | Payload hash mismatch |
| `UNIPAY_ERR_INVALID_AMOUNT` | `process_payment`, `process_bank_topup` | 400 | Amount ≤ 0 |
| `UNIPAY_ERR_SELF_PAYMENT` | `process_payment` | 400 | Payer = payee |
| `UNIPAY_ERR_PAYER_WALLET_INVALID` | `process_payment` | 403 | Payer not active |
| `UNIPAY_ERR_PAYEE_WALLET_INVALID` | `process_payment` | 403 | Payee not active |
| `UNIPAY_ERR_REFUND_EXCEEDS_ORIGINAL` | `process_payment` | 400 | Refund > original |
| `UNIPAY_ERR_SETTLEMENT_AMOUNT_MISMATCH` | `process_settlement` | 500 | Amount ≠ balance |
| `UNIPAY_ERR_LEDGER_IMMUTABLE` | `prevent_ledger_mutation` | 500 | Mutation attempt |
| `UNIPAY_ERR_SHEET_ALREADY_CLOSED` | `close_sheet` | 409 | Sheet not active |
| `UNIPAY_ERR_NOT_CREATOR` | `close_sheet`, `manual_add_attendance` | 403 | Not sheet owner |
| `UNIPAY_ERR_SHEET_STILL_ACTIVE` | `manual_add_attendance` | 409 | Sheet not closed yet |
| `UNIPAY_ERR_USER_NOT_FOUND` | `manual_add_attendance` | 404 | Index number unknown |