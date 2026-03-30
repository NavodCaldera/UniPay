# UniPay — Migration Rules and Strategy

> **AI Instruction**: This file defines the rules for writing, naming,
> and running database migrations. Never edit a migration file after it
> has been committed. Never run migrations directly against production —
> always test on a Neon staging branch first. When asked to add a column
> or change a schema, always produce a new migration file rather than
> editing an existing schema file.

---

## 1. What a Migration Is

A migration is a SQL file that transforms the database from one state
to another. Migrations are:

- **Append-only** — once written and committed, never edited
- **Sequential** — must be run in order, never skipped
- **Idempotent where possible** — safe to run twice without error
- **Reversible where possible** — each file includes a rollback comment

The `schemas/` files represent the current desired state.
The `migrations/` files represent the journey from empty to that state.
Both must be kept in sync — every change to `schemas/` needs a migration.

---

## 2. Naming Convention

```
YYYYMMDD_NNN_short_description.sql

Examples:
  20260324_001_extensions_and_enums.sql
  20260324_002_users_and_sessions.sql
  20260324_003_wallets_and_vans.sql
  20260324_004_merchants_and_skus.sql
  20260324_005_ledger.sql
  20260324_006_attendance.sql
  20260324_007_analytics.sql
  20260324_008_notifications.sql
  20260324_009_stored_functions.sql
  20260324_010_views.sql
  20260324_011_indexes.sql
  20260324_012_privileges.sql
  20260324_013_seed_production.sql
```

**Rules for names:**
- Date prefix is the date the migration was created, not deployed
- NNN is a three-digit sequence starting from 001
- Description uses underscores, lowercase, no spaces
- Description is short but specific — not "update" or "fix"
- If two migrations are created on the same day, NNN increments: 001, 002

---

## 3. Migration File Structure

Every migration file follows this exact template:

```sql
-- ============================================================
-- Migration: 20260324_005_ledger.sql
-- Description: Creates transactions and ledger_entries tables
-- Author: Navod Caldera
-- Date: 2026-03-24
-- Depends on: 20260324_003_wallets_and_vans.sql
-- ============================================================

-- ── FORWARD MIGRATION ────────────────────────────────────────

CREATE TABLE transactions (
  -- ... column definitions
);

CREATE INDEX idx_transactions_payer ON transactions(payer_wallet_id, created_at DESC);

-- ── ROLLBACK (manual — run only if this migration must be undone) ──
-- WARNING: This will permanently delete all transaction data.
-- Only run during initial setup, never in production.
--
-- DROP TABLE IF EXISTS transactions CASCADE;
-- DROP TABLE IF EXISTS ledger_entries CASCADE;
```

---

## 4. The Current Migration Sequence

All migrations in dependency order:

| File | What it does |
|---|---|
| `20260324_001_extensions_and_enums.sql` | Enables pgcrypto, pg_trgm. Creates all 15 ENUM types. |
| `20260324_002_users_and_sessions.sql` | Creates `users` and `user_sessions` tables. |
| `20260324_003_wallets_and_vans.sql` | Creates `wallets` and `vans` tables. |
| `20260324_004_merchants_and_skus.sql` | Creates `merchants` and `skus` tables. |
| `20260324_005_ledger.sql` | Creates `transactions`, `ledger_entries`, `settlement_failures` tables. |
| `20260324_006_attendance.sql` | Creates `attendance_sheets`, `attendance_records`, `submission_attempts` tables. |
| `20260324_007_analytics.sql` | Creates `campus_presence`, `lunch_probability`, `demand_forecasts` tables. |
| `20260324_008_notifications.sql` | Creates `notifications` table. |
| `20260324_009_stored_functions.sql` | Creates all stored functions in correct dependency order. |
| `20260324_010_views.sql` | Creates all views. |
| `20260324_011_indexes.sql` | Creates all indexes not already defined inline. |
| `20260324_012_privileges.sql` | Sets `unipay_app` and `unipay_migrations` role privileges. |
| `20260324_013_triggers.sql` | Creates `set_updated_at`, `prevent_ledger_mutation` triggers. |

---

## 5. Running Migrations

Migrations are run using the `migrate.sh` script in `infrastructure/scripts/`.

```bash
# Run all pending migrations against the dev branch
./infrastructure/scripts/migrate.sh dev

# Run all pending migrations against staging branch
./infrastructure/scripts/migrate.sh staging

# Run all pending migrations against production (requires confirmation)
./infrastructure/scripts/migrate.sh prod
```

The script:
1. Reads the `DATABASE_URL` for the target environment from `.env.*`
2. Checks which migrations have already run (via a `_migrations` tracking table)
3. Runs only the new migrations in order
4. Logs success or failure for each file
5. Stops on the first failure — does not continue to the next file

---

## 6. Testing Migrations with Neon Branching

Before running any migration against production, test it on a Neon branch:

```bash
# 1. Create a branch from production (instant — copy-on-write snapshot)
neon branches create --name migration-test --parent main

# 2. Get the connection string for the new branch
neon connection-string migration-test

# 3. Run the migration against the branch
DATABASE_URL="<branch-connection-string>" ./migrate.sh branch

# 4. Verify the migration worked correctly
# Run the application against the branch and test

# 5a. If successful — run against production
./migrate.sh prod

# 5b. If failed — delete the branch and fix the migration
neon branches delete migration-test
# Edit the migration file (it has not been committed yet)
# Repeat from step 1
```

**Critical**: A migration file is only committed to git AFTER it has
been successfully tested on a Neon branch. Never commit and push a
migration file that has not been tested.

---

## 7. Safe and Unsafe Operations

### Safe (no downtime, no table lock):
```sql
-- Adding a new column with a default value
ALTER TABLE users ADD COLUMN profile_complete BOOLEAN NOT NULL DEFAULT FALSE;

-- Adding a new enum value
ALTER TYPE transaction_type ADD VALUE 'new_value';

-- Adding an index concurrently (does not lock writes)
CREATE INDEX CONCURRENTLY idx_new_index ON table_name(column);

-- Creating a new table
CREATE TABLE new_table (...);

-- Adding a constraint to a new table (before data exists)
ALTER TABLE new_table ADD CONSTRAINT ...;

-- Using CREATE OR REPLACE for stored functions
CREATE OR REPLACE FUNCTION function_name(...) ...;
```

### Unsafe (may cause downtime or table lock):
```sql
-- Adding a NOT NULL column without a default to a table with existing rows
-- SOLUTION: Add nullable first, backfill, then add NOT NULL constraint
ALTER TABLE users ADD COLUMN new_col TEXT;       -- Step 1: nullable
UPDATE users SET new_col = 'default_value';      -- Step 2: backfill
ALTER TABLE users ALTER COLUMN new_col SET NOT NULL; -- Step 3: constraint

-- Removing a column (may break running application code)
-- SOLUTION: Deploy application code that ignores the column first,
-- then remove the column in a separate migration

-- Removing an enum value (table rewrite required)
-- See enums.md — Safe ENUM Migration Strategy

-- Adding a non-concurrent index on a large table
-- SOLUTION: Always use CREATE INDEX CONCURRENTLY

-- Changing a column's data type
-- May require a full table rewrite
-- SOLUTION: Add new column, backfill, swap, drop old column
```

---

## 8. The `_migrations` Tracking Table

The `migrate.sh` script creates and maintains a tracking table:

```sql
CREATE TABLE IF NOT EXISTS _migrations (
  id          SERIAL      PRIMARY KEY,
  filename    TEXT        NOT NULL UNIQUE,
  run_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  success     BOOLEAN     NOT NULL DEFAULT TRUE
);
```

Before running each file, the script checks:
```sql
SELECT 1 FROM _migrations WHERE filename = '20260324_005_ledger.sql';
```

If the row exists, the file is skipped. If not, it is run and a row
is inserted on success. This makes the migration system idempotent —
safe to run multiple times.

---

## 9. Emergency Hotfix Migration

If a critical bug requires an immediate schema fix in production:

```
1. Write the fix as a new migration file with today's date
2. Test it on a Neon branch against a copy of production data
3. Run it against production during lowest-traffic period (e.g. 03:00 LKT)
4. Commit the migration file to git immediately after production run
5. Document the emergency in the PR description
```

Never apply schema changes to production that are not in a migration
file. Never apply migration files that are not committed to git.

---

## 10. Adding a New Feature — Checklist

When adding a new feature that requires database changes:

```
[ ] Write the new table/column definitions in the relevant schemas/ file
[ ] Write a new migration file with the next sequence number
[ ] Test the migration on a Neon staging branch
[ ] Update tables.md with the new column definitions
[ ] Update enums.md if new enum values are added
[ ] Update functions.md if new stored functions are added
[ ] Update the shared/types/ TypeScript interfaces
[ ] Update the shared/constants/ if new enum values affect constants
[ ] Commit schemas/ changes, migration file, and docs in the same PR
```