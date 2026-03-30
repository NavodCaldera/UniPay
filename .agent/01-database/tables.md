# UniPay — Table Reference

> **AI Instruction**: This file is the authoritative reference for every
> table in the UniPay database. Before writing any SQL query, migration,
> or stored function — verify the exact column names, types, and
> constraints here. Do not assume column names from memory.
> Tables are listed in dependency order — referenced tables appear
> before the tables that reference them.

---

## Dependency Order

```
users
  └── user_sessions       (references users)
  └── wallets             (references users)
      └── vans            (references users, wallets)
  └── merchants           (references users)
      └── skus            (references merchants)
  └── transactions        (references wallets, merchants)
      └── ledger_entries  (references transactions, wallets)
  └── attendance_sheets   (references users)
      └── attendance_records    (references attendance_sheets, users)
      └── submission_attempts   (references users)
  └── campus_presence     (references users)
  └── lunch_probability   (references users)
  └── demand_forecasts    (references merchants)
  └── notifications       (references users)
  └── settlement_failures (references merchants, wallets)
```

---

## 1. `users`

The central identity table. All four roles live here. The single most
important table in the system — everything else references it.

```sql
CREATE TABLE users (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  role                user_role     NOT NULL,
  status              user_status   NOT NULL DEFAULT 'active',

  -- Identity
  full_name           TEXT          NOT NULL,
  email               TEXT          NOT NULL UNIQUE,
  google_id           TEXT          UNIQUE,        -- Firebase Google OAuth UID
  avatar_url          TEXT,                        -- Profile photo URL from Google

  -- University identity
  -- NULL for lecturers, merchants, and admins
  -- Required for marking attendance (capability gate)
  university_index    TEXT          UNIQUE,        -- e.g. "230001A"
  department          TEXT,                        -- e.g. "Computer Science"
  batch_year          SMALLINT,                    -- e.g. 2023 (undergraduates only)
  expected_grad_year  SMALLINT,                    -- Used for VAN quarantine timing

  -- Audit
  created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_users_role             ON users(role);
CREATE INDEX idx_users_university_index ON users(university_index)
  WHERE university_index IS NOT NULL;
CREATE INDEX idx_users_google_id        ON users(google_id)
  WHERE google_id IS NOT NULL;
```

**Key rules:**
- `university_index` is the attendance marking gate — NULL means cannot mark
- `expected_grad_year` drives VAN quarantine — set at enrollment, rarely changed
- `updated_at` is maintained by the `set_updated_at()` trigger

---

## 2. `user_sessions`

One row per active device login. Enables remote session revocation
without invalidating all sessions across all devices.

```sql
CREATE TABLE user_sessions (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,

  -- The JWT ID claim — used to check revocation in KV and DB
  jwt_jti       TEXT          NOT NULL UNIQUE,

  -- Human-readable device label for the "active sessions" UI
  -- e.g. "Chrome on Android", "Safari on iPhone"
  device_label  TEXT,

  -- Revocation: NULL = active, timestamp = revoked
  revoked_at    TIMESTAMPTZ,

  created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_user_sessions_user_id ON user_sessions(user_id);
CREATE INDEX idx_user_sessions_jti     ON user_sessions(jwt_jti);
-- Partial index for active sessions only (the common lookup)
CREATE INDEX idx_user_sessions_active  ON user_sessions(jwt_jti)
  WHERE revoked_at IS NULL;
```

**Key rules:**
- `jwt_jti` is the UUID from the JWT payload — checked on every API request
- `revoked_at` being non-null means the session is invalid
- The KV revocation cache is the fast path; this table is the audit trail

---

## 3. `wallets`

One wallet per user. Stores the current balance as a denormalised
cache of the ledger. The ledger is the source of truth.

```sql
CREATE TABLE wallets (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID          NOT NULL UNIQUE REFERENCES users(id) ON DELETE RESTRICT,
  type            wallet_type   NOT NULL,
  status          wallet_status NOT NULL DEFAULT 'active',

  -- Balance in cents — BIGINT, never DECIMAL
  -- CHECK constraint enforces the balance floor at DB level
  balance_cents   BIGINT        NOT NULL DEFAULT 0
                  CHECK (balance_cents >= 0),

  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_wallets_user_id ON wallets(user_id);
CREATE INDEX idx_wallets_type    ON wallets(type, status);
```

**Key rules:**
- One wallet per user — enforced by `UNIQUE (user_id)`
- `balance_cents >= 0` is the overdraft prevention constraint
- `balance_cents` is updated only by stored functions — never raw SQL
- `updated_at` is maintained by the `set_updated_at()` trigger

---

## 4. `vans`

Virtual Account Number pool. VANs are issued by the partner bank and
stored here for JIT allocation to students.

```sql
CREATE TABLE vans (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  van_number            TEXT        NOT NULL UNIQUE,  -- Real bank account number
  status                van_status  NOT NULL DEFAULT 'available',

  -- Assignment
  assigned_to           UUID        REFERENCES users(id) ON DELETE SET NULL,
  assigned_at           TIMESTAMPTZ,

  -- Graduation snapshot — copied from users.expected_grad_year at assignment
  -- Stored here so profile edits don't alter the quarantine schedule
  grad_year_snapshot    SMALLINT,

  -- Lifecycle timestamps
  deactivated_at        TIMESTAMPTZ,  -- Set when student graduates

  -- Computed quarantine boundaries — maintained by PostgreSQL, never manually set
  quarantine_starts_at  TIMESTAMPTZ GENERATED ALWAYS AS (
    deactivated_at + INTERVAL '6 months'
  ) STORED,
  recycle_eligible_at   TIMESTAMPTZ GENERATED ALWAYS AS (
    deactivated_at + INTERVAL '18 months'
  ) STORED,

  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_vans_status       ON vans(status);
CREATE INDEX idx_vans_assigned_to  ON vans(assigned_to)
  WHERE assigned_to IS NOT NULL;
CREATE INDEX idx_vans_lifecycle    ON vans(quarantine_starts_at, recycle_eligible_at)
  WHERE status IN ('assigned', 'quarantined');
```

---

## 5. `merchants`

Merchant profile linked to a user. One user can only be one merchant.

```sql
CREATE TABLE merchants (
  id                    UUID      PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               UUID      NOT NULL UNIQUE REFERENCES users(id) ON DELETE RESTRICT,
  business_name         TEXT      NOT NULL,
  location_label        TEXT,                -- e.g. "Main Canteen, Block A"

  -- QR Code
  -- The HMAC-signed payload embedded in the static QR sticker
  qr_code_payload       TEXT      NOT NULL UNIQUE,

  -- Bank details for nightly settlement
  -- Stored encrypted at rest — never returned in API responses
  bank_account_number   TEXT      NOT NULL,
  bank_code             TEXT      NOT NULL,  -- Bank identifier code

  -- Settlement tracking
  settlement_failure_count  INT   NOT NULL DEFAULT 0,

  is_active             BOOLEAN   NOT NULL DEFAULT TRUE,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_merchants_user_id ON merchants(user_id);
CREATE INDEX idx_merchants_active  ON merchants(is_active)
  WHERE is_active = TRUE;
```

---

## 6. `skus`

Per-merchant product catalogue. Every purchase stores SKU-level
receipt data in the transaction's `receipt_payload` JSONB.

```sql
CREATE TABLE skus (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id   UUID          NOT NULL REFERENCES merchants(id) ON DELETE CASCADE,
  name          TEXT          NOT NULL,         -- e.g. "Rice and Curry"
  category      sku_category  NOT NULL DEFAULT 'other',
  price_cents   INT           NOT NULL CHECK (price_cents > 0),
  is_available  BOOLEAN       NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_skus_merchant_id ON skus(merchant_id);
CREATE INDEX idx_skus_available   ON skus(merchant_id, is_available)
  WHERE is_available = TRUE;
```

---

## 7. `transactions`

The immutable financial event ledger. Every money movement creates
exactly one row here and exactly two rows in `ledger_entries`.
Never UPDATE or DELETE. Never write directly — use stored functions.

```sql
CREATE TABLE transactions (
  id                        UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
  type                      transaction_type    NOT NULL,
  status                    transaction_status  NOT NULL DEFAULT 'pending',

  -- Parties
  payer_wallet_id           UUID                REFERENCES wallets(id) ON DELETE RESTRICT,
  payee_wallet_id           UUID                REFERENCES wallets(id) ON DELETE RESTRICT,
  merchant_id               UUID                REFERENCES merchants(id) ON DELETE RESTRICT,

  -- Amount in cents
  amount_cents              BIGINT              NOT NULL CHECK (amount_cents > 0),

  -- SKU-level receipt — nullable (present for purchases, null for topups/settlements)
  -- Example:
  -- {"items": [{"sku_id": "...", "name": "Rice", "qty": 1, "unit_price_cents": 65000}]}
  receipt_payload           JSONB,

  -- Idempotency — client-generated UUID, prevents double charges
  idempotency_key           UUID                UNIQUE,

  -- SHA-256 of request payload — prevents forged retries
  payload_hash              CHAR(64),

  -- Bank integration
  bank_reference            TEXT                UNIQUE,  -- Bank's event ID for topups/settlements

  -- For refunds: points back to the original purchase transaction
  reference_transaction_id  UUID                REFERENCES transactions(id) ON DELETE RESTRICT,

  -- Audit
  completed_at              TIMESTAMPTZ,
  created_at                TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_transactions_payer      ON transactions(payer_wallet_id, created_at DESC);
CREATE INDEX idx_transactions_payee      ON transactions(payee_wallet_id, created_at DESC);
CREATE INDEX idx_transactions_merchant   ON transactions(merchant_id, created_at DESC);
CREATE INDEX idx_transactions_status     ON transactions(status)
  WHERE status NOT IN ('completed', 'failed');
CREATE INDEX idx_transactions_receipt    ON transactions USING GIN (receipt_payload);
CREATE INDEX idx_transactions_bank_ref   ON transactions(bank_reference)
  WHERE bank_reference IS NOT NULL;
```

---

## 8. `ledger_entries`

Double-entry accounting entries. Two rows per transaction.
Immutable — enforced by triggers and database role privileges.
The balance_after_cents column provides a point-in-time balance
snapshot for statement generation without recalculating from scratch.

```sql
CREATE TABLE ledger_entries (
  id                    UUID              PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id        UUID              NOT NULL
                        REFERENCES transactions(id) ON DELETE RESTRICT,
  wallet_id             UUID              NOT NULL
                        REFERENCES wallets(id) ON DELETE RESTRICT,
  direction             ledger_direction  NOT NULL,
  amount_cents          BIGINT            NOT NULL CHECK (amount_cents > 0),
  balance_after_cents   BIGINT            NOT NULL CHECK (balance_after_cents >= 0),
  created_at            TIMESTAMPTZ       NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_ledger_wallet_id       ON ledger_entries(wallet_id, created_at DESC);
CREATE INDEX idx_ledger_transaction_id  ON ledger_entries(transaction_id);
```

---

## 9. `attendance_sheets`

One row per attendance session. Created by any authenticated user.
Duration stored in seconds — UI shows minutes + seconds separately.

```sql
CREATE TABLE attendance_sheets (
  id                UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by        UUID            NOT NULL REFERENCES users(id) ON DELETE RESTRICT,

  -- Module information
  module_code       TEXT            NOT NULL,   -- e.g. "CS3012"
  module_name       TEXT            NOT NULL,   -- e.g. "Machine Learning"

  -- Session timing
  sheet_date        DATE            NOT NULL DEFAULT CURRENT_DATE,
  closing_time      TIME            NOT NULL,   -- Scheduled lecture end time

  -- Attendance window
  -- Stored as total seconds — UI collects minutes + seconds separately
  -- Minimum: 30 seconds. Maximum: 3600 seconds (1 hour).
  duration_seconds  INT             NOT NULL
                    CHECK (duration_seconds BETWEEN 30 AND 3600),

  -- The 5-character attendance code
  -- Generated from ambiguity-free pool: ABCDEFGHJKLMNPQRTUVWXYZabcdefghjkmnpqrtuvwxyz23456789
  -- Excludes: 0 O 1 l I 5 S
  code              CHAR(5)         NOT NULL UNIQUE,
  code_expires_at   TIMESTAMPTZ     NOT NULL,

  -- Lifecycle
  status            session_status  NOT NULL DEFAULT 'active',
  closed_at         TIMESTAMPTZ,

  -- Excel export trigger
  export_ready      BOOLEAN         NOT NULL DEFAULT FALSE,

  -- Live counter — denormalised for fast dashboard reads
  total_marked      INT             NOT NULL DEFAULT 0,

  created_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_expires_after_created CHECK (code_expires_at > created_at)
);

-- Indexes
CREATE INDEX idx_sheets_created_by  ON attendance_sheets(created_by, sheet_date DESC);
CREATE INDEX idx_sheets_code        ON attendance_sheets(code, code_expires_at)
  WHERE status = 'active';
CREATE INDEX idx_sheets_export      ON attendance_sheets(export_ready)
  WHERE export_ready = FALSE AND status != 'active';
```

---

## 10. `attendance_records`

One row per successful attendance mark. Present-only model —
absent means no row exists.

```sql
CREATE TABLE attendance_records (
  id                  UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
  sheet_id            UUID                NOT NULL
                      REFERENCES attendance_sheets(id) ON DELETE CASCADE,
  user_id             UUID                NOT NULL
                      REFERENCES users(id) ON DELETE CASCADE,

  -- Identity snapshot at time of marking
  -- Stored here so the Excel is correct even if the user later
  -- changes their name or university_index
  university_index    TEXT                NOT NULL,
  full_name           TEXT                NOT NULL,

  -- Submission metadata
  status              attendance_status   NOT NULL DEFAULT 'present',
  submitted_at        TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
  submitted_ip        INET,
  network_type        network_type,
  is_flagged          BOOLEAN             NOT NULL DEFAULT FALSE,

  -- Manual addition by creator (post-close)
  manual_add          BOOLEAN             NOT NULL DEFAULT FALSE,
  manual_add_by       UUID                REFERENCES users(id),
  manual_add_at       TIMESTAMPTZ,
  manual_add_reason   TEXT,

  -- One mark per user per session
  UNIQUE (sheet_id, user_id),

  CONSTRAINT chk_index_not_empty CHECK (
    university_index IS NOT NULL AND university_index != ''
  )
);

-- Indexes
CREATE INDEX idx_records_sheet    ON attendance_records(sheet_id, submitted_at ASC);
CREATE INDEX idx_records_user     ON attendance_records(user_id, submitted_at DESC);
CREATE INDEX idx_records_flagged  ON attendance_records(sheet_id)
  WHERE is_flagged = TRUE;
```

---

## 11. `submission_attempts`

All attendance code submission attempts — successful and failed.
The fraud audit trail. Never deleted.

```sql
CREATE TABLE submission_attempts (
  id            UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID                NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  code_entered  CHAR(5)             NOT NULL,
  submitted_ip  INET,
  network_type  network_type,
  outcome       submission_outcome  NOT NULL,
  attempted_at  TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_attempts_user     ON submission_attempts(user_id, attempted_at DESC);
CREATE INDEX idx_attempts_outcome  ON submission_attempts(outcome, attempted_at DESC);
CREATE INDEX idx_attempts_fraud    ON submission_attempts(user_id, outcome)
  WHERE outcome = 'wrong_code';
```

---

## 12. `campus_presence`

Daily student presence pool. Populated when a student makes a
transaction during a specific rush period. Used by the Pulse Score
calculation and demand forecasting.

```sql
CREATE TABLE campus_presence (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id          UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date                DATE          NOT NULL DEFAULT CURRENT_DATE,
  rush_period         rush_period   NOT NULL,
  first_signal_at     TIMESTAMPTZ,  -- Time of the first presence signal in this period
  confirmed_present   BOOLEAN       NOT NULL DEFAULT FALSE,

  UNIQUE (student_id, date, rush_period)
);

-- Indexes
CREATE INDEX idx_presence_date    ON campus_presence(date, rush_period, confirmed_present);
CREATE INDEX idx_presence_student ON campus_presence(student_id, date DESC);
```

---

## 13. `lunch_probability`

Four-week rolling per-student, per-day-of-week conversion probability.
Updated after each day by the analytics cron. Used in the Pulse Score
C component — but C was removed from the simplified equation.
Retained for future demand forecasting features.

```sql
CREATE TABLE lunch_probability (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id          UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  day_of_week         SMALLINT      NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  observation_count   INT           NOT NULL DEFAULT 0,
  lunch_tx_count      INT           NOT NULL DEFAULT 0,
  probability         NUMERIC(5,4)  NOT NULL DEFAULT 0.5,
  last_updated        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  UNIQUE (student_id, day_of_week)
);
```

---

## 14. `demand_forecasts`

Computed Campus Pulse scores and expected covers per merchant per
rush period. Written by `compute_traffic_score()` and read by the
merchant POS dashboard via KV cache.

```sql
CREATE TABLE demand_forecasts (
  id                      UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id             UUID          NOT NULL REFERENCES merchants(id) ON DELETE CASCADE,
  forecast_date           DATE          NOT NULL,
  rush_period             rush_period   NOT NULL,
  forecasted_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  -- Pulse score: T = round(P × 100)
  -- P = confirmed_present / historical_avg_present, capped at 1.0
  traffic_score           SMALLINT      NOT NULL CHECK (traffic_score BETWEEN 0 AND 100),

  -- Presence data used in calculation
  confirmed_present       INT           NOT NULL DEFAULT 0,
  historical_avg_present  NUMERIC(8,2)  NOT NULL DEFAULT 0,
  presence_ratio          NUMERIC(5,4)  NOT NULL DEFAULT 0,

  -- SKU-level breakdown (future demand forecasting)
  sku_breakdown           JSONB,

  UNIQUE (merchant_id, forecast_date, rush_period)
);

-- Indexes
CREATE INDEX idx_forecasts_merchant ON demand_forecasts(merchant_id, forecast_date DESC);
```

---

## 15. `notifications`

In-app notifications for all user roles. Read by the frontend on
dashboard load and on the notification bell tap.

```sql
CREATE TABLE notifications (
  id            UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID                NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type          notification_type   NOT NULL,
  title         TEXT                NOT NULL,
  body          TEXT                NOT NULL,
  is_read       BOOLEAN             NOT NULL DEFAULT FALSE,
  created_at    TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_notifications_user   ON notifications(user_id, created_at DESC);
CREATE INDEX idx_notifications_unread ON notifications(user_id, is_read)
  WHERE is_read = FALSE;
```

---

## 16. `settlement_failures`

Failed nightly settlement attempts. Preserved for admin review and
manual resolution. A merchant cannot be settled again until
the failure is resolved or the admin overrides.

```sql
CREATE TABLE settlement_failures (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id       UUID        NOT NULL REFERENCES merchants(id) ON DELETE RESTRICT,
  wallet_id         UUID        NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
  amount_cents      BIGINT      NOT NULL,
  settlement_date   DATE        NOT NULL,
  attempt_number    SMALLINT    NOT NULL DEFAULT 1,
  error_message     TEXT        NOT NULL,
  resolved_at       TIMESTAMPTZ,         -- NULL until manually resolved by admin
  resolved_by       UUID        REFERENCES users(id),
  resolution_notes  TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_settlement_failures_merchant    ON settlement_failures(merchant_id);
CREATE INDEX idx_settlement_failures_unresolved  ON settlement_failures(resolved_at)
  WHERE resolved_at IS NULL;
```

---

## Column Name Quick Reference

When writing queries, use these exact column names:

| Table | Common columns |
|---|---|
| `users` | `id, role, status, full_name, email, google_id, university_index, department, batch_year, expected_grad_year` |
| `user_sessions` | `id, user_id, jwt_jti, device_label, revoked_at` |
| `wallets` | `id, user_id, type, status, balance_cents` |
| `vans` | `id, van_number, status, assigned_to, assigned_at, deactivated_at, quarantine_starts_at, recycle_eligible_at` |
| `merchants` | `id, user_id, business_name, location_label, qr_code_payload, bank_account_number, bank_code, is_active` |
| `skus` | `id, merchant_id, name, category, price_cents, is_available` |
| `transactions` | `id, type, status, payer_wallet_id, payee_wallet_id, merchant_id, amount_cents, receipt_payload, idempotency_key, payload_hash, bank_reference, reference_transaction_id, completed_at` |
| `ledger_entries` | `id, transaction_id, wallet_id, direction, amount_cents, balance_after_cents` |
| `attendance_sheets` | `id, created_by, module_code, module_name, sheet_date, closing_time, duration_seconds, code, code_expires_at, status, closed_at, export_ready, total_marked` |
| `attendance_records` | `id, sheet_id, user_id, university_index, full_name, status, submitted_at, submitted_ip, network_type, is_flagged, manual_add, manual_add_by, manual_add_at, manual_add_reason` |
| `submission_attempts` | `id, user_id, code_entered, submitted_ip, network_type, outcome, attempted_at` |
| `campus_presence` | `id, student_id, date, rush_period, first_signal_at, confirmed_present` |
| `demand_forecasts` | `id, merchant_id, forecast_date, rush_period, traffic_score, confirmed_present, historical_avg_present, presence_ratio` |
| `notifications` | `id, user_id, type, title, body, is_read` |
| `settlement_failures` | `id, merchant_id, wallet_id, amount_cents, settlement_date, attempt_number, error_message, resolved_at` |