-- Role: Developer A - Financial Core
-- Database: PostgreSQL (Neon)

-- 1. Ledger Entries (Immutable)
CREATE TABLE ledger_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key TEXT UNIQUE NOT NULL,
    debit_account_id UUID NOT NULL,
    credit_account_id UUID NOT NULL,
    amount DECIMAL(12, 2) NOT NULL CHECK (amount > 0),
    currency TEXT DEFAULT 'LKR',
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Virtual Accounts (Balances)
CREATE TABLE virtual_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT UNIQUE NOT NULL, -- Firebase UID
    balance DECIMAL(12, 2) DEFAULT 0.00 CHECK (balance >= 0.00),
    role TEXT NOT NULL CHECK (role IN ('student', 'merchant', 'system')),
    status TEXT DEFAULT 'active',
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Audit Logs
CREATE TABLE audit_logs (
    id SERIAL PRIMARY KEY,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    action TEXT NOT NULL,
    old_data JSONB,
    new_data JSONB,
    actor_id TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexing for performance
CREATE INDEX idx_ledger_debit ON ledger_entries(debit_account_id);
CREATE INDEX idx_ledger_credit ON ledger_entries(credit_account_id);
