# UniPay — Table Schemas

> **AI Instruction**: This file defines the exact, bank-grade FinTech table structures for UniPay. Never alter these constraints, never remove the observability fields, and always enforce the Double-Entry Ledger rules.

## Schema Directives
- **UUIDv7 Constraints**: All primary keys MUST use `uuid_generate_v7()` to prevent B-Tree index fragmentation under high concurrency.
- **Audit & Observability**: Critical state changes must capture `client_ip` and `user_agent`.
- **Immutability**: The `ledger_entries` and `transaction_events` tables are STRICTLY append-only. 

---

```sql
-- ==========================================
-- 1. IDENTITY & AUTHENTICATION
-- ==========================================

CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
    firebase_uid VARCHAR(128) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    role user_role NOT NULL,
    status user_status NOT NULL DEFAULT 'active', -- Account-level lock
    full_name VARCHAR(255) NOT NULL,
    university_index VARCHAR(20) UNIQUE,          -- e.g., '230000X'
    expected_grad_year INT,                       -- Used for graduation expiry
    
    -- VAN is optional and only for students/lecturers
    virtual_account_number VARCHAR(30) UNIQUE, 
    
    -- BANK-GRADE RULE: Only students/lecturers can have a bank bridge.
    CONSTRAINT check_van_eligibility CHECK (
        virtual_account_number IS NULL OR 
        (role IN ('undergraduate', 'lecturer'))
    ),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Fast lookup for Bank Webhooks (Filtered Index)
CREATE INDEX idx_users_van ON users(virtual_account_number) WHERE (virtual_account_number IS NOT NULL);

CREATE TABLE user_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    jwt_jti UUID UNIQUE NOT NULL, 
    client_ip INET NOT NULL,      
    user_agent TEXT,              
    revoked_at TIMESTAMPTZ,       
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL 
);

-- ==========================================
-- 1.5 MERCHANT BANKING (FOR SETTLEMENTS)
-- ==========================================

CREATE TABLE merchant_bank_accounts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
    merchant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    bank_name VARCHAR(100) NOT NULL,      
    branch_name VARCHAR(100) NOT NULL,    
    account_number VARCHAR(30) NOT NULL,
    account_name VARCHAR(255) NOT NULL,   
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    is_verified BOOLEAN NOT NULL DEFAULT FALSE, -- Requires Admin approval
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_one_primary_account_per_merchant 
ON merchant_bank_accounts (merchant_id) WHERE (is_primary = TRUE);

-- ==========================================
-- 2. THE TRUE DOUBLE-ENTRY LEDGER
-- ==========================================

CREATE TABLE wallets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
    user_id UUID NOT NULL REFERENCES users(id),
    type wallet_type NOT NULL,
    balance_cents BIGINT NOT NULL DEFAULT 0, 
    daily_spent_cents BIGINT NOT NULL DEFAULT 0, -- Counter for UI display only
    status wallet_status NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT unique_user_wallet UNIQUE(user_id),
    CONSTRAINT zero_overdraft CHECK (balance_cents >= 0)
);

CREATE TABLE transaction_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
    type transaction_type NOT NULL,
    status transaction_status NOT NULL DEFAULT 'pending', 
    idempotency_key UUID UNIQUE NOT NULL, 
    payload_hash VARCHAR(64) NOT NULL,    
    metadata JSONB,                       
    client_ip INET NOT NULL,              
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for Admin daily reporting / high-speed sorting
CREATE INDEX idx_transactions_created_at ON transaction_events(created_at DESC);

CREATE TABLE ledger_entries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
    transaction_event_id UUID NOT NULL REFERENCES transaction_events(id),
    wallet_id UUID NOT NULL REFERENCES wallets(id),
    amount_cents BIGINT NOT NULL, 
    direction ledger_direction NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT enforce_entry_direction CHECK (
        (direction = 'debit' AND amount_cents < 0) OR 
        (direction = 'credit' AND amount_cents > 0)
    )
);

-- Optimization for high-speed balance recalculations and mobile history
CREATE INDEX idx_ledger_wallet_time ON ledger_entries(wallet_id, created_at DESC);
CREATE INDEX idx_ledger_event_id ON ledger_entries(transaction_event_id);

-- ==========================================
-- 3. THE ATTENDANCE ENGINE
-- ==========================================

CREATE TABLE attendance_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
    creator_id UUID NOT NULL REFERENCES users(id),
    module_code VARCHAR(20) NOT NULL,
    module_name VARCHAR(255) NOT NULL,
    session_secret UUID NOT NULL DEFAULT uuid_generate_v7(), 
    duration_seconds INT NOT NULL CHECK (duration_seconds >= 30),
    closed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE attendance_records (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
    session_id UUID NOT NULL REFERENCES attendance_sessions(id),
    student_id UUID NOT NULL REFERENCES users(id),
    network_type VARCHAR(50) NOT NULL DEFAULT 'unknown', 
    is_manual_add BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT unique_student_session UNIQUE(session_id, student_id) 
);