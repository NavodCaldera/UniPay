# UniPay — Database Overview

> **AI Instruction**: This file defines the core database philosophy and architecture for UniPay. Every SQL statement, migration, and query written must strictly adhere to these rules. This is a bank-grade FinTech system; do not suggest shortcuts, loose constraints, or application-layer trust.

---

## 1. Core Database Stack
- **Provider**: Neon (Serverless PostgreSQL 15+)
- **Environment**: Cloudflare Workers Edge Runtime (V8)
- **Driver**: `@neondatabase/serverless` (HTTP/WebSocket-based connection)
- **Connection Pooling**: PgBouncer (Managed natively by Neon to handle massive concurrent connection spikes)
- **Timezone**: All timestamps must be `TIMESTAMPTZ` and stored natively in UTC.

> **CRITICAL EDGE RULE**: Standard TCP-based PostgreSQL drivers (like `pg`) will crash the Cloudflare Worker. You must exclusively use `@neondatabase/serverless`.

---

## 2. The 10 Golden Rules of the FinTech Engine

### Rule 1: Integer Cents Only (No Decimals)
All monetary values are stored as `BIGINT` representing Sri Lankan Cents (LKR 1.00 = 100 cents).
**Never** use `DECIMAL`, `NUMERIC`, or `FLOAT`. Floating-point math introduces rounding errors.

### Rule 2: Zero Overdraft Database Guarantee
The application layer is never trusted to prevent overdrafts. The database must physically prevent negative balances using a table-level constraint: `CHECK (balance_cents >= 0)`. Furthermore, stored procedures must perform a fast-fail `SELECT ... balance_cents` check before executing updates to prevent late rollbacks and disk thrashing.

### Rule 3: The True Double-Entry Ledger
UniPay relies on a strict Double-Entry system. Every financial event inserts **one** row into `transaction_events` (the intent) and exactly **two** rows into `ledger_entries` (the money movement—one credit, one debit). 
**The Vault Lock:** The database stored procedure must execute a hard `SUM(amount_cents) = 0` check across the newly created ledger entries before committing. If it does not equal zero, it must roll back.

### Rule 4: Deterministic Concurrency Locks
To completely eliminate the risk of database deadlocks during high-volume concurrent payments and refunds, wallets must ALWAYS be locked in deterministic, canonical order. Stored procedures must lock the mathematically "lesser" UUID first using `LEAST()` and `GREATEST()`.

### Rule 5: Strict Isolation & Atomicity
All money movement happens entirely inside PostgreSQL via atomic PL/pgSQL stored procedures (`process_payment`). This guarantees the execution block acts sequentially. If multi-step transactions are ever required outside a stored procedure, they must be executed under the `SERIALIZABLE` transaction isolation level.

### Rule 6: UUIDv7 for Index Performance
Every table must use time-sorted UUIDv7s for its primary key.
Because PostgreSQL 15 does not natively support UUIDv7, we rely on a custom PL/pgSQL function (`uuid_generate_v7()`). **Never** use completely random UUIDv4s (`gen_random_uuid()`), as they cause severe B-Tree index fragmentation and IOPS spikes under heavy write loads.

### Rule 7: Cryptographic Idempotency
To prevent double-charging from network retries, every transaction requires an `idempotency_key` (enforced via a `UNIQUE` constraint). 
**Anti-Forgery:** This key must be bound to the payload mathematically. The stored procedure must check if a retry attempts to use the same idempotency key with a *different* `amount_cents` and explicitly reject it as a forgery.

### Rule 8: Built-in Observability
All critical identity and financial tables (`user_sessions`, `transaction_events`) must capture the client's IP address (`INET`) and User-Agent. 

### Rule 9: Strict Enums
Never use loose `VARCHAR` for statuses, types, or roles. Always use predefined PostgreSQL `ENUM` types (defined in `enums.md`). 

### Rule 10: Present-Only Attendance Model
The `attendance_records` table only stores rows for students who are *present*. Absence is mathematically inferred by the lack of a row for a specific `session_id` and `student_id`.

---

## 3. Migration Strategy

UniPay uses a strict, append-only migration strategy.

1. **Timestamped Files**: Migrations are numbered sequentially (e.g., `001_initial_schema.sql`).
2. **Immutability**: Once a migration has been executed against the production database, the file must never be edited.
3. **Rollbacks**: If a mistake is made, you must create a *new* migration (e.g., `003_fix_ledger.sql`) that corrects the schema. Do not write `down` migrations; always roll forward.