# UniPay — Database Functions & Procedures

> **AI Instruction**: This file defines the executable logic of the database. These functions must be deployed via migrations. NEVER alter the deterministic locking order, NEVER remove the hard ledger balance checks, and NEVER bypass the payload hash anti-forgery check.

---

-- ==========================================
-- PREREQUISITES
-- ==========================================
-- REQUIRED: Enables gen_random_bytes() for the UUIDv7 generator
CREATE EXTENSION IF NOT EXISTS pgcrypto;

---

## 1. Custom UUIDv7 Generator
*Purpose: Solves PostgreSQL 15's lack of native UUIDv7 for sequential, time-sorted indexing. Prevents severe B-Tree fragmentation on the `ledger_entries` table. Optimized for multi-core batch inserts.*

```sql
CREATE OR REPLACE FUNCTION uuid_generate_v7()
RETURNS uuid
AS $$
DECLARE
    unix_time_ms bytea;
    uuid_bytes bytea;
BEGIN
    -- Get current UNIX time in milliseconds
    unix_time_ms := substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3);
    
    -- Generate 10 bytes of randomness
    uuid_bytes := gen_random_bytes(10);
    
    -- Set the version (7) and variant (10) bits
    uuid_bytes := set_byte(uuid_bytes, 0, (get_byte(uuid_bytes, 0) & 15) | 112); -- Version 7
    uuid_bytes := set_byte(uuid_bytes, 2, (get_byte(uuid_bytes, 2) & 63) | 128); -- Variant 10
    
    -- Concatenate time and randomness
    RETURN (encode(unix_time_ms, 'hex') || encode(uuid_bytes, 'hex'))::uuid;
END
$$
LANGUAGE plpgsql 
VOLATILE 
PARALLEL SAFE; -- Unlocks multi-core CPU execution for batch inserts

CREATE OR REPLACE FUNCTION process_payment(
    p_payer_wallet_id UUID,
    p_payee_wallet_id UUID,
    p_amount_cents BIGINT,
    p_transaction_type transaction_type,
    p_idempotency_key UUID,
    p_payload_hash VARCHAR(64),
    p_client_ip INET,
    p_metadata JSONB DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    v_event_id UUID;
    v_existing_hash VARCHAR(64);
    v_payer_balance BIGINT;
    v_payer_status wallet_status;
    v_payee_status wallet_status;
    v_ledger_sum BIGINT;
    v_lock_first UUID;
    v_lock_second UUID;
BEGIN
    -- ==========================================
    -- 0. Prevent Self-Dealing Exploit
    -- ==========================================
    IF p_payer_wallet_id = p_payee_wallet_id THEN
        RAISE EXCEPTION 'Cannot transfer funds to the same wallet' USING ERRCODE = 'check_violation';
    END IF;

    -- ==========================================
    -- 1. Idempotency & Anti-Forgery Check
    -- ==========================================
    SELECT id, payload_hash INTO v_event_id, v_existing_hash 
    FROM transaction_events 
    WHERE idempotency_key = p_idempotency_key;

    IF FOUND THEN
        -- If the key exists but the hash of the request is different, it's a forgery/tamper attempt.
        IF v_existing_hash != p_payload_hash THEN
            RAISE EXCEPTION 'Idempotency forgery: Key reused with different payload' 
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        -- If it's a legitimate retry, return the original success ID immediately.
        RETURN v_event_id; 
    END IF;

    -- ==========================================
    -- 2. Deterministic Concurrency Locking
    -- ==========================================
    -- ALWAYS lock the mathematically "lesser" UUID first. 
    -- This physically prevents deadlocks if two wallets try to pay/refund each other at the exact same millisecond.
    v_lock_first := LEAST(p_payer_wallet_id, p_payee_wallet_id);
    v_lock_second := GREATEST(p_payer_wallet_id, p_payee_wallet_id);

    PERFORM id FROM wallets WHERE id = v_lock_first FOR UPDATE;
    PERFORM id FROM wallets WHERE id = v_lock_second FOR UPDATE;

    -- ==========================================
    -- 3. Fast-Fail Overdraft & Status Checks
    -- ==========================================
    SELECT balance_cents, status INTO v_payer_balance, v_payer_status FROM wallets WHERE id = p_payer_wallet_id;
    SELECT status INTO v_payee_status FROM wallets WHERE id = p_payee_wallet_id;

    IF v_payer_status != 'active' OR v_payee_status != 'active' THEN
        RAISE EXCEPTION 'One or both wallets are not active' USING ERRCODE = 'check_violation';
    END IF;

    IF v_payer_balance < p_amount_cents THEN
        RAISE EXCEPTION 'Insufficient funds' USING ERRCODE = 'check_violation';
    END IF;

    -- ==========================================
    -- 4. Execute Wallet Updates
    -- ==========================================
    UPDATE wallets 
    SET balance_cents = balance_cents - p_amount_cents, 
        
        updated_at = NOW() 
    WHERE id = p_payer_wallet_id;
    
    UPDATE wallets 
    SET balance_cents = balance_cents + p_amount_cents, 
        updated_at = NOW() 
    WHERE id = p_payee_wallet_id;

    -- ==========================================
    -- 5. Record the Intent (The Event)
    -- ==========================================
    -- Note: Because this function only executes on success, we hardcode the status to 'completed'.
    -- The Edge API handles logging 'failed' or 'pending' events directly.
    INSERT INTO transaction_events (type, status, idempotency_key, payload_hash, metadata, client_ip)
    VALUES (p_transaction_type, 'completed', p_idempotency_key, p_payload_hash, p_metadata, p_client_ip)
    RETURNING id INTO v_event_id;

    -- ==========================================
    -- 6. Record the Double-Entry Ledger
    -- ==========================================
    INSERT INTO ledger_entries (transaction_event_id, wallet_id, amount_cents, direction)
    VALUES 
        (v_event_id, p_payer_wallet_id, (p_amount_cents * -1), 'debit'),
        (v_event_id, p_payee_wallet_id, p_amount_cents, 'credit');

    -- ==========================================
    -- 7. Hard Global Consistency Check (The Vault Lock)
    -- ==========================================
    SELECT SUM(amount_cents) INTO v_ledger_sum 
    FROM ledger_entries 
    WHERE transaction_event_id = v_event_id;

    IF v_ledger_sum != 0 THEN
        -- If this triggers, something is fundamentally broken in the physics of the DB. 
        -- Raising an exception forces an immediate rollback of EVERYTHING in this function.
        RAISE EXCEPTION 'CRITICAL: Ledger Imbalance Detected (Sum != 0). Rolling back entirely.';
    END IF;

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql STRICT;