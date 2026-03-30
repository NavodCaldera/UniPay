# UniPay — Database Overview

> **AI Instruction**: Read this file before writing any SQL, any database
> query, or any code that interacts with the database. Every rule here
> is non-negotiable. Do not suggest alternatives to Neon, do not suggest
> DECIMAL for money, do not suggest auto-increment IDs. These decisions
> are final and exist for specific reasons documented below.

---

## 1. Why Neon

Neon is a serverless PostgreSQL provider. It was chosen over standard
PostgreSQL hosting (RDS, Supabase, Railway) for three specific reasons:

**Cloudflare Workers compatibility.** Standard PostgreSQL uses TCP
connections. Cloudflare Workers run in an edge runtime that does not
support TCP. Neon's `@neondatabase/serverless` driver communicates over
HTTP and WebSockets, which Workers support natively. No other PostgreSQL
provider offers a production-ready Workers-compatible driver.

**Serverless scaling.** Neon scales to zero when idle and scales up
instantly on demand. For a campus system that has zero activity between
22:00 and 06:00 LKT, this means zero compute cost during off-hours.
Traditional always-on PostgreSQL charges 24/7 regardless of load.

**Branching for safe migrations.** Neon supports database branches —
an instant copy-on-write snapshot of the entire database. Every migration
is tested on a branch before being applied to production. If the migration
has a problem, the branch is deleted and production is untouched.

---

## 2. The Twelve Non-Negotiable Database Rules

```
RULE 01 — MONEY IS BIGINT CENTS
         All monetary values are stored as BIGINT in cents.
         1 LKR = 100 cents. LKR 650.00 = 65000 cents.
         NEVER use DECIMAL, FLOAT, REAL, or NUMERIC for money.
         Floating-point arithmetic produces rounding errors.
         DECIMAL is slower than BIGINT for high-frequency writes.
         Integer arithmetic is exact, fast, and simple.

RULE 02 — ALL PRIMARY KEYS ARE UUID
         Every table uses UUID PRIMARY KEY DEFAULT gen_random_uuid().
         Never use SERIAL or BIGSERIAL auto-increment IDs.
         Reasons: UUIDs are safe to generate client-side without a DB
         round trip, they do not leak row counts or insertion order to
         users, and they work correctly in distributed systems.

RULE 03 — ALL TIMESTAMPS ARE TIMESTAMPTZ IN UTC
         Every timestamp column is TIMESTAMPTZ (timestamp with timezone).
         All values are stored in UTC.
         Conversion to Asia/Colombo (UTC+5:30) happens at the API layer
         when formatting for display — never in the database query.
         Never use TIMESTAMP WITHOUT TIME ZONE anywhere.

RULE 04 — ENUMS FOR ALL STATUS AND ROLE COLUMNS
         Never use VARCHAR for a column that has a fixed set of values.
         All statuses, roles, types, and directions use PostgreSQL ENUMs
         defined in database/schemas/enums.sql.
         This enforces valid values at the database level — not just in
         application code that can be bypassed.

RULE 05 — TRANSACTIONS TABLE IS APPEND-ONLY
         Never UPDATE or DELETE a row in the transactions table.
         Never UPDATE or DELETE a row in the ledger_entries table.
         Reversals are new rows. Corrections are new rows.
         An immutable audit trail is a legal requirement for FinTech.

RULE 06 — BALANCE FLOOR IS DATABASE-ENFORCED
         wallets.balance_cents has CHECK (balance_cents >= 0).
         The database rejects any UPDATE that would produce a negative
         balance. The Worker does NOT pre-check the balance — the DB
         constraint is the authority. This prevents race conditions
         where two concurrent payments both read a positive balance
         and both succeed, producing a negative result.

RULE 07 — PROCESS_PAYMENT() IS THE ONLY WAY TO MOVE MONEY
         The Worker never issues raw UPDATE statements against
         wallets.balance_cents for payment flows.
         All balance changes go through atomic stored functions:
           - process_payment()      for purchases and preorders
           - process_bank_topup()   for VAN deposits
           - process_settlement()   for nightly merchant settlement

RULE 08 — ATTENDANCE USES PRESENT-ONLY MODEL
         There are no 'absent' rows in attendance_records for students
         who did not submit. Absent means no row exists.
         The close_sheet() function creates absent records only for
         enrolled students who never submitted — and only in modules
         that use enrollment tracking.
         This keeps the table lean and the export query simple.

RULE 09 — FOREIGN KEYS USE ON DELETE RESTRICT
         All foreign keys default to ON DELETE RESTRICT.
         No CASCADE deletes exist in the financial tables.
         A transaction cannot be deleted while it has ledger entries.
         A wallet cannot be deleted while it has transactions.
         Data is never physically deleted — it is status-flagged.

RULE 10 — THE LEDGER IS THE GROUND TRUTH
         wallets.balance_cents is a denormalised cache of the ledger.
         If they ever disagree, the ledger wins.
         The reconciliation queries in database/views/ verify agreement
         nightly. Any discrepancy triggers an admin alert.

RULE 11 — MIGRATIONS ARE APPEND-ONLY
         Once a migration file is committed and run against any
         environment, it is never edited.
         Schema changes always go in a new migration file.
         This creates a complete, auditable history of every database
         change ever made to the system.

RULE 12 — APPLICATION USER HAS MINIMUM REQUIRED PRIVILEGES
         The application database role has:
           SELECT, INSERT on all tables
           UPDATE on wallets, users, vans, merchants, skus,
                   attendance_sheets, campus_presence, lunch_probability
           NO UPDATE on transactions, ledger_entries (immutable)
           NO DELETE on any table
         This is enforced via GRANT statements in the migration files.
```

---

## 3. Table Inventory

All twelve core tables and their one-line purpose:

| Table | Purpose |
|---|---|
| `users` | All platform users across all four roles |
| `user_sessions` | Active device login sessions for JWT revocation |
| `wallets` | One wallet per user — stores balance in cents |
| `vans` | Virtual Account Number pool for bank topups |
| `merchants` | Merchant profiles linked to a user |
| `skus` | Per-merchant product and menu items |
| `transactions` | Immutable financial event ledger |
| `ledger_entries` | Double-entry accounting entries per transaction |
| `attendance_sheets` | Attendance sessions created by any user |
| `attendance_records` | Individual student attendance submissions |
| `submission_attempts` | All code submission attempts including failures |
| `campus_presence` | Daily student presence pool for analytics |
| `lunch_probability` | 4-week rolling lunch conversion probability per student |
| `demand_forecasts` | Computed merchant demand predictions with pulse score |
| `notifications` | In-app notifications for all user roles |
| `settlement_failures` | Failed nightly settlement attempts for admin review |

Full column definitions for every table are in `01-database/tables.md`.

---

## 4. File Structure and When to Use Each

```
database/
├── schemas/          The current desired state — what the DB looks like now
│   ├── enums.sql     All ENUM type definitions
│   ├── users.sql     users + user_sessions tables
│   ├── wallets.sql   wallets + vans tables
│   ├── merchants.sql merchants + skus tables
│   ├── ledger.sql    transactions + ledger_entries + settlement_failures
│   ├── attendance.sql attendance_sheets + records + submission_attempts
│   ├── analytics.sql campus_presence + lunch_probability + demand_forecasts
│   └── notifications.sql notifications table
│
├── functions/        Stored functions — atomic database operations
│   ├── payment/      process_payment, process_bank_topup, process_settlement
│   ├── attendance/   create_sheet, mark_attendance, close_sheet etc.
│   ├── analytics/    compute_traffic_score
│   └── shared/       set_updated_at, prevent_ledger_mutation
│
├── views/            Read-optimised query definitions
│   ├── v_wallet_statement.sql
│   ├── v_sheet_summary.sql
│   ├── v_flagged_submissions.sql
│   ├── v_merchant_dashboard.sql
│   ├── v_van_pool_status.sql
│   └── v_settlement_report.sql
│
├── migrations/       Append-only deployment history
│   └── YYYYMMDD_NNN_description.sql
│
└── seed/             Development and staging test data only
    ├── seed_users.sql
    ├── seed_merchants.sql
    ├── seed_wallets.sql
    └── seed_attendance.sql
```

**When to use schemas/ vs migrations/:**

`schemas/` files represent the current state of the database. They are
used for understanding the system and for setting up a fresh environment.
They are not run in sequence — they represent the end state.

`migrations/` files are run in sequence to get from one state to another.
They are what actually runs against production. Every change to `schemas/`
must have a corresponding `migrations/` file.

Think of it this way:
- `schemas/` is the blueprint of what the building looks like today
- `migrations/` is the construction diary of every change ever made

---

## 5. Neon Connection Configuration

```typescript
// database/db/client.ts
import { neon } from '@neondatabase/serverless';

export function getDB(env: Env) {
  return neon(env.DATABASE_URL);
}
```

**Connection string format:**
```
postgres://user:password@ep-xxx-xxx.us-east-1.aws.neon.tech/neondb?sslmode=require
```

**Environment-specific databases:**

| Environment | Neon Branch | Used for |
|---|---|---|
| Development | `dev` branch | Local development — safe to reset |
| Staging | `staging` branch | Migration testing before production |
| Production | `main` branch | Live system — never reset |

The `DATABASE_URL` environment variable points to the correct branch
for each deployment environment. This is set in `infrastructure/env/`.

---

## 6. Index Strategy

Every index in the system is defined immediately after its table in the
`schemas/` files and in the final migration. The indexing philosophy:

**Index every foreign key.** PostgreSQL does not automatically index
foreign keys. An unindexed foreign key causes full table scans on every
JOIN. Every `_id` column that is a foreign key has an index.

**Index every column used in WHERE clauses.** Columns used in common
WHERE clauses — `status`, `created_at`, `session_date`, `university_index`
— have indexes. Partial indexes are used where appropriate (e.g. only
indexing active sessions, not all historical ones).

**No over-indexing.** Indexes slow down writes. Every index in this
system has a documented reason for existing. Do not add indexes
speculatively — add them when a slow query is observed.

**Composite indexes for common query patterns.** Queries like "all
transactions for a wallet ordered by date" use a composite index on
`(wallet_id, created_at DESC)` rather than two separate single-column
indexes.

---

## 7. Timezone Handling

All timestamps are stored as `TIMESTAMPTZ` in UTC.

**In the database:** Always `NOW()` which returns UTC.

**In the Worker:** Convert to LKT for display only:
```typescript
// utils/time.ts
export function toDisplayTime(utcTimestamp: string): string {
  return new Date(utcTimestamp).toLocaleString('en-LK', {
    timeZone: 'Asia/Colombo',
    dateStyle: 'medium',
    timeStyle: 'short'
  });
}
```

**In SQL queries that filter by date:** Always cast to LKT before
comparing to a date:
```sql
-- WRONG — compares UTC date, misses events between 18:30 and 00:00 LKT
WHERE DATE(created_at) = '2026-03-29'

-- RIGHT — compares LKT date correctly
WHERE DATE(created_at AT TIME ZONE 'Asia/Colombo') = '2026-03-29'
```

The cron jobs (`vanReclaim.ts`, `nightlySettlement.ts`, `refreshTrafficScore.ts`)
all use LKT times internally but Cloudflare cron triggers are configured
in UTC. The UTC equivalents are documented in `08-worker/cron-jobs.md`.

---

## 8. Database User Privileges

Two database roles exist:

**`unipay_app`** — used by the Cloudflare Worker at runtime:
```sql
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA public TO unipay_app;
GRANT UPDATE ON
  wallets, users, vans, merchants, skus,
  attendance_sheets, campus_presence,
  lunch_probability, demand_forecasts,
  user_sessions, notifications
TO unipay_app;
-- Deliberately NO UPDATE on: transactions, ledger_entries
-- Deliberately NO DELETE on: any table
```

**`unipay_migrations`** — used only by the `migrate.sh` script:
```sql
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO unipay_migrations;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO unipay_migrations;
```

The migration role is never used at runtime. Its credentials are stored
only in `infrastructure/env/.env.prod` and are not available to the
Worker deployment.

---

## 9. Reconciliation Schedule

The following integrity checks run automatically:

| Check | When | Alert threshold |
|---|---|---|
| Transaction zero-sum | Nightly after settlement | Any non-zero result |
| Wallet balance vs ledger | Nightly after settlement | Any discrepancy |
| Master Trust balance | Nightly after settlement | Any discrepancy |
| VAN pool available count | Daily at 09:00 LKT | Below 200 VANs |
| Settlement failure count | After each settlement run | Any failure |

Full reconciliation SQL is in `database/views/` and documented in
`03-payment/ledger.md`.

---

## 10. Related Files

- `01-database/enums.md` — all enum values explained
- `01-database/tables.md` — full column definitions per table
- `01-database/functions.md` — all stored functions reference
- `01-database/views.md` — all views and their consumers
- `01-database/migrations.md` — migration naming and deployment rules
- `01-database/seed.md` — test data and how to load it
- `database/schemas/` — the actual SQL files
- `database/functions/` — the stored function SQL files