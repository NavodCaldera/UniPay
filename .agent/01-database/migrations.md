# UniPay — Database Migrations

> **AI Instruction**: This file defines the strict protocol for modifying the UniPay database schema. Every database change MUST be written as a raw SQL migration file. Never suggest using ORM auto-sync features (e.g., `drizzle-kit push`) in production.

---

## 1. The Migration Philosophy

UniPay uses an **Append-Only, Forward-Rolling** migration strategy. Financial databases must maintain a perfect, immutable history of how their schemas evolved. 

1. **Raw SQL Only**: Migrations must be written in raw PostgreSQL syntax.
2. **Immutability**: Once a migration file is merged into the `main` branch and executed against the production database, **it is permanently locked**. You must NEVER edit a past migration file.
3. **No Down Migrations**: We do not write `DOWN` migrations (rollback scripts). If a migration introduces a bug, you must write a *new* migration (a "Roll Forward" script) to fix it or revert the change.

---

## 2. File Naming Convention

All migrations live in the `worker/migrations/` directory. 
They must be prefixed with a sequential 4-digit number to guarantee execution order.

**Format:** `XXXX_descriptive_name.sql`

**Example History:**
- `0001_initial_auth_schema.sql`
- `0002_create_ledger_tables.sql`
- `0003_add_uuidv7_and_payment_functions.sql`
- `0004_fix_merchant_spelling_error.sql` *(Example of a roll-forward fix)*

---

## 3. Writing Safe Migrations (Rules of Engagement)

When generating SQL for a migration, you must adhere to these safety checks:

### A. Idempotent Executions
Whenever safely possible, use `IF NOT EXISTS` or `OR REPLACE` so that if a migration fails halfway through, running it again will not crash.
- **Good:** `CREATE TABLE IF NOT EXISTS users (...)`
- **Good:** `CREATE OR REPLACE FUNCTION process_payment (...)`

### B. Transactional Blocks
Unless the migration tool wraps files in transactions automatically, explicitly wrap multi-statement schema changes in a transaction block so they succeed or fail as a single unit.
```sql
BEGIN;

ALTER TABLE wallets ADD COLUMN temp_limit BIGINT;
UPDATE wallets SET temp_limit = 500000;

COMMIT;

```
### C. The 2-Second Rule (Lock Timeouts)
To prevent a migration from "queueing" behind a long-running payment and taking the app offline, every migration file MUST start by setting a lock timeout. 
-- Good: If it can't get a lock in 2 seconds, it fails safely instead of causing an outage.
SET lock_timeout = '2s'; 

### D. Zero-Downtime Indexing
Never create indexes on production tables using standard `CREATE INDEX`. It locks the table. Use the concurrent approach, but remember: this CANNOT be inside a `BEGIN/COMMIT` block.
-- Good (Run outside of a transaction):
CREATE INDEX CONCURRENTLY idx_ledger_status ON ledger_entries(status);

### E. The "Daily Reset" Logic
Since we need to reset `daily_spent_cents` at midnight, do not use a migration for the reset logic. Instead, use a migration to create a CRON trigger (if using Neon's `pg_cron`) or a stored procedure that your Cloudflare Worker can call via a Cron Trigger.

### F. The Constraint Validation Trap
Never add a constraint to a table with existing data using a simple ADD CONSTRAINT. It will lock the table to validate old data. Use the "Two-Step Validation" instead.

-- Step 1: Add the constraint (Instant lock, doesn't check old data)
ALTER TABLE wallets ADD CONSTRAINT check_max_balance CHECK (balance_cents < 100000000) NOT VALID;

-- Step 2: Validate it (Does NOT lock the table while checking)
ALTER TABLE wallets VALIDATE CONSTRAINT check_max_balance;

### G. Handling Failed Concurrent Indexes
If `CREATE INDEX CONCURRENTLY` fails (e.g., due to a timeout), PostgreSQL leaves behind an "INVALID" index. You must manually drop it before trying again.
-- Check for invalid indexes before retrying:
-- DROP INDEX CONCURRENTLY IF EXISTS idx_name;

### H. The Billion-Row Barrier (Partitioning)
The `ledger_entries` table WILL grow to billions of rows. We must use Time-Based Partitioning.
- **Rule:** Never perform a sequential scan on `ledger_entries` in a migration.
- **Rule:** If altering a partitioned table, perform the change on the parent table; PostgreSQL will propagate it, but ensure `lock_timeout` is strictly enforced.

### I. No "Mass Data Updates"
Never run a single `UPDATE` or `DELETE` statement that affects more than 10,000 rows in a migration. This causes massive transaction log (WAL) bloat and locks.
- **Good:** Perform data migrations in small, asynchronous batches via a dedicated script, NOT a schema migration file.

### J. Zero-Downtime Foreign Keys
Adding a Foreign Key requires a lock on both the source and target tables. 
-- Step 1: Add the FK without validation (Instant)
ALTER TABLE ledger_entries ADD CONSTRAINT fk_wallet 
FOREIGN KEY (wallet_id) REFERENCES wallets(id) NOT VALID;

-- Step 2: Validate later (No long-term locks)
ALTER TABLE ledger_entries VALIDATE CONSTRAINT fk_wallet;