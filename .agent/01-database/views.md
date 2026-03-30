# UniPay — Database Views Reference

> **AI Instruction**: Views are read-optimised query definitions that the
> Worker and cron jobs use instead of writing raw JOIN queries inline.
> Never bypass a view by writing the same query inline in a controller —
> use the view. Views live in database/views/. Call them exactly as
> documented here.

---

## 1. `v_wallet_statement`

**File:** `database/views/v_wallet_statement.sql`
**Used by:** `GET /api/v1/users/me/wallet/statement`
**Consumer:** Student transaction history screen, merchant daily summary

Returns a chronological, human-readable transaction history for any wallet.
Includes counterparty name, signed amount, and balance snapshot.

```sql
SELECT * FROM v_wallet_statement
WHERE wallet_id = $1
ORDER BY timestamp DESC
LIMIT 50 OFFSET $2;
```

**Columns returned:**

| Column | Type | Description |
|---|---|---|
| `transaction_id` | UUID | Transaction identifier |
| `timestamp` | TIMESTAMPTZ | When the transaction completed (UTC) |
| `transaction_type` | transaction_type | Type of event |
| `direction` | ledger_direction | debit or credit for this wallet |
| `amount_cents` | BIGINT | Unsigned amount |
| `signed_amount_cents` | BIGINT | Negative for debit, positive for credit |
| `balance_after_cents` | BIGINT | Wallet balance after this event |
| `counterparty_name` | TEXT | Merchant name, "Bank Transfer", or "System" |
| `receipt` | JSONB | SKU line items (null for non-purchase types) |

**Performance:** Relies on `idx_ledger_wallet_id` and `idx_transactions_merchant`.
Safe to call on every page load — no aggregation, simple JOIN.

---

## 2. `v_sheet_summary`

**File:** `database/views/v_sheet_summary.sql`
**Used by:** `GET /api/v1/attendance/sheets`
**Consumer:** Sheet creator's history page

Returns all attendance sheets created by a user with computed statistics.

```sql
SELECT * FROM v_sheet_summary
WHERE created_by_id = $1
ORDER BY sheet_date DESC, created_at DESC;
```

**Columns returned:**

| Column | Type | Description |
|---|---|---|
| `sheet_id` | UUID | Sheet identifier |
| `module_code` | TEXT | e.g. "CS3012" |
| `module_name` | TEXT | e.g. "Machine Learning" |
| `created_by_id` | UUID | Creator user UUID |
| `created_by_name` | TEXT | Creator full name |
| `sheet_date` | DATE | Date of the session |
| `closing_time` | TIME | Scheduled lecture end |
| `duration_seconds` | INT | Window duration in seconds |
| `duration_label` | TEXT | Human-readable e.g. "2m 30s" |
| `code` | CHAR(5) | The attendance code |
| `code_expires_at` | TIMESTAMPTZ | When the code expired or expires |
| `status` | session_status | active, expired, or closed |
| `total_marked` | INT | Number of successful submissions |
| `export_ready` | BOOLEAN | Whether the Excel file is ready |
| `closed_at` | TIMESTAMPTZ | When the session ended |
| `seconds_remaining` | INT | Seconds left (0 if closed) |
| `attendance_pct` | NUMERIC | Percentage present (if enrollment tracked) |
| `created_at` | TIMESTAMPTZ | When the sheet was created |

---

## 3. `v_flagged_submissions`

**File:** `database/views/v_flagged_submissions.sql`
**Used by:** Attendance fraud review — lecturer dashboard
**Consumer:** `GET /api/v1/attendance/sheets/:id/flagged`

Returns all submissions from non-Eduroam networks for a sheet.
Used to help the sheet creator identify suspected buddy-punching.

```sql
SELECT * FROM v_flagged_submissions
WHERE sheet_id = $1
ORDER BY submitted_at ASC;
```

**Columns returned:**

| Column | Type | Description |
|---|---|---|
| `record_id` | UUID | Attendance record identifier |
| `sheet_id` | UUID | Sheet identifier |
| `university_index` | TEXT | Student index number |
| `full_name` | TEXT | Student name |
| `submitted_at` | TIMESTAMPTZ | When the code was submitted |
| `network_type` | network_type | cellular_dialog, cellular_mobitel, unknown |
| `submitted_ip` | INET | IP address at submission |
| `module_code` | TEXT | Module context |
| `sheet_date` | DATE | Session date |

---

## 4. `v_merchant_dashboard`

**File:** `database/views/v_merchant_dashboard.sql`
**Used by:** `GET /api/v1/merchants/me/dashboard`
**Consumer:** Merchant POS today summary

Returns the merchant's current day summary — balance, transaction count,
and revenue by transaction type. Intended for the POS landing view.

```sql
SELECT * FROM v_merchant_dashboard
WHERE merchant_id = $1;
```

**Columns returned:**

| Column | Type | Description |
|---|---|---|
| `merchant_id` | UUID | Merchant identifier |
| `business_name` | TEXT | Merchant display name |
| `current_balance_cents` | BIGINT | Current unsettled wallet balance |
| `today_revenue_cents` | BIGINT | Total received today (LKT date) |
| `today_tx_count` | INT | Number of payments received today |
| `today_purchase_cents` | BIGINT | Revenue from purchases |
| `today_preorder_cents` | BIGINT | Revenue from preorders |
| `last_payment_at` | TIMESTAMPTZ | Most recent payment received |
| `morning_pulse` | SMALLINT | Pulse score for morning period (from KV or DB) |
| `lunch_pulse` | SMALLINT | Pulse score for lunch period |
| `dinner_pulse` | SMALLINT | Pulse score for dinner period |

**Performance note:** This view is NOT cached. It queries live data.
The pulse score columns join to `demand_forecasts` — the Worker should
read pulse scores from KV cache first and only fall through to this
view if the KV entry has expired.

---

## 5. `v_van_pool_status`

**File:** `database/views/v_van_pool_status.sql`
**Used by:** `GET /api/v1/admin/vans/status`
**Consumer:** Admin dashboard VAN pool health widget

Returns a count and percentage breakdown of VANs by status.

```sql
SELECT * FROM v_van_pool_status;
```

**Columns returned:**

| Column | Type | Description |
|---|---|---|
| `status` | van_status | VAN lifecycle state |
| `count` | INT | Number of VANs in this state |
| `pct` | NUMERIC | Percentage of total pool |

**Alert logic:** If `status = 'available'` and `count < 200`, the admin
dashboard shows a red warning and triggers a `low_van_pool` notification.

---

## 6. `v_settlement_report`

**File:** `database/views/v_settlement_report.sql`
**Used by:** `GET /api/v1/merchants/me/settlements/:date`
**Consumer:** Merchant settlement history screen

Returns a detailed breakdown of a merchant's settlement for a specific
trading day, including all individual transactions included in the batch.

```sql
SELECT * FROM v_settlement_report
WHERE merchant_id = $1
  AND trading_date = $2::date;
```

**Columns returned:**

| Column | Type | Description |
|---|---|---|
| `settlement_id` | UUID | Settlement transaction UUID |
| `merchant_id` | UUID | Merchant identifier |
| `trading_date` | DATE | Day being settled |
| `settled_at` | TIMESTAMPTZ | When the settlement processed |
| `settled_cents` | BIGINT | Total amount transferred to bank |
| `bank_reference` | TEXT | Bank transfer reference for verification |
| `transaction_count` | INT | Number of student payments included |
| `gross_revenue_cents` | BIGINT | Sum of all purchases for that day |
| `transactions` | JSONB | Array of individual transactions with receipt data |

---

## View Performance Notes

| View | Query cost | Cache recommended? | TTL if cached |
|---|---|---|---|
| `v_wallet_statement` | Low — indexed range scan | No | — |
| `v_sheet_summary` | Low — indexed by creator | No | — |
| `v_flagged_submissions` | Low — partial index | No | — |
| `v_merchant_dashboard` | Medium — aggregation | Yes (KV) | 30 seconds |
| `v_van_pool_status` | Low — small table | Yes (KV) | 5 minutes |
| `v_settlement_report` | Medium — JSON aggregation | Yes (KV) | 1 hour |

For views marked "cache recommended", the Worker reads from KV first
and only queries the view if the KV entry is missing or expired.
The KV key format is: `view:{view_name}:{primary_key}:{date}`