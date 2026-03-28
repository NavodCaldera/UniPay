# UniPay — Database Seeding

> **AI Instruction**: This file defines the protocol for seeding the database with initial test data for local development and staging. NEVER execute seed scripts against the production database.

---

## 1. Seeding Philosophy

Because UniPay enforces strict FinTech constraints (Double-Entry Ledger, Zero Overdraft, Deterministic Locking), seeding data must be done carefully to avoid constraint violations. 

1. **Static Test UUIDs**: For local development, use static, predictable UUIDs (e.g., `11111111-1111-7000-8000-000000000001`) for key test accounts so the frontend team can hardcode test logins without querying the DB every time.
2. **Sequential Insertion**: You must respect foreign key constraints. Order of insertion: `users` -> `wallets` -> `attendance_sessions` (Optional).
3. **Use the Engine for Money**: NEVER manually insert rows into `transaction_events` or `ledger_entries` to give a test user a starting balance. You must call the `process_payment()` stored procedure to simulate a bank top-up.

---

## 2. Standard Test Accounts (Local Environment)

Every seed script must always generate these three baseline accounts:

1. **System Master (Admin)**: The central vault that mints money for testing (represents the actual Bank/Payment Gateway).
2. **Main Canteen (Merchant)**: The primary test merchant.
3. **Test Undergraduate (Student)**: The primary user for testing the mobile UI.

---

## 3. Example Seed Script (`seed.sql`)

When generating a seed file, follow this exact structure to safely populate the database using our stored procedures:

```sql
BEGIN;

-- ==========================================
-- 0. CLEANUP (The "Fresh Start" Protocol)
-- ==========================================
-- CASCADE ensures that wallets and ledger entries are wiped alongside users.
TRUNCATE users, wallets, transaction_events, ledger_entries RESTART IDENTITY CASCADE;

-- ==========================================
-- 1. CREATE USERS
-- ==========================================
-- System Master (Admin)
INSERT INTO users (id, firebase_uid, email, role, full_name) 
VALUES ('00000000-0000-7000-8000-000000000000', 'fb-admin-seed', 'admin@unipay.lk', 'admin', 'System Master');

-- Merchant (Canteen)
INSERT INTO users (id, firebase_uid, email, role, full_name) 
VALUES ('22222222-2222-7000-8000-000000000000', 'fb-merch-seed', 'canteen@unipay.lk', 'merchant', 'Main Canteen');

-- Student (Navod)
INSERT INTO users (id, firebase_uid, email, role, full_name, university_index, expected_grad_year, virtual_account_number) 
VALUES ('33333333-3333-7000-8000-000000000000', 'fb-stud-seed', 'student@unipay.lk', 'undergraduate', 'Navod Caldera', '230000X', 2027, 'VAN-UOM-230000X');

-- Add this to Section 1 (CREATE USERS) or a new section in seed.sql
-- ==========================================
-- 1.1 MERCHANT BANK DETAILS
-- ==========================================
INSERT INTO merchant_bank_accounts (
    merchant_id, 
    bank_name, 
    branch_name, 
    account_number, 
    account_name, 
    is_primary
) 
VALUES (
    '22222222-2222-7000-8000-000000000000', -- Main Canteen ID
    'Bank of Ceylon', 
    'Moratuwa', 
    '8877665544', 
    'UOM Main Canteen Official', 
    TRUE
);

-- ==========================================
-- 2. CREATE WALLETS
-- ==========================================
-- System Wallet (Central Bank - Starts with 1 Million LKR)
INSERT INTO wallets (id, user_id, type, balance_cents, status) 
VALUES ('00000000-0000-7000-8000-111111111111', '00000000-0000-7000-8000-000000000000', 'system', 100000000, 'active');

-- Suspense Wallet (For orphaned/closed account funds)
INSERT INTO wallets (id, user_id, type, balance_cents, status) 
VALUES ('00000000-0000-7000-8000-999999999999', '00000000-0000-7000-8000-000000000000', 'suspense', 0, 'active');

-- Merchant Wallet
INSERT INTO wallets (id, user_id, type, balance_cents, status) 
VALUES ('22222222-2222-7000-8000-111111111111', '22222222-2222-7000-8000-000000000000', 'merchant', 0, 'active');

-- Student Wallet (Must use 'personal' type per enums.md)
INSERT INTO wallets (id, user_id, type, balance_cents, status) 
VALUES ('33333333-3333-7000-8000-111111111111', '33333333-3333-7000-8000-000000000000', 'personal', 0, 'active');

-- ==========================================
-- 3. INITIAL FUNDING (Using the Secure Engine)
-- ==========================================
-- Give the test student 5,000 LKR via a simulated bank top-up.
-- This ensures the ledger entries are correctly generated from day one.
SELECT process_payment(
    '00000000-0000-7000-8000-111111111111', -- Payer: System Master
    '33333333-3333-7000-8000-111111111111', -- Payee: Student
    500000,                                 -- Amount: 5,000.00 LKR
    'bank_topup',                           -- Type
    'ffffffff-ffff-4000-a000-000000000000', -- Static Idempotency Key
    'SEED_HASH_VALIDATION_BYPASS',          -- Payload Hash
    '127.0.0.1',                            -- Client IP
    jsonb_build_object(
        'bank_ref', 'BOC-TXN-SEED-001',
        'method', 'Virtual Account Transfer',
        'is_seed', true
    )
);

COMMIT;