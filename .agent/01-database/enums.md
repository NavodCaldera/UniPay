# UniPay — Database Enums

> **AI Instruction**: This file defines the strictly allowed ENUM types for the database. When writing table schemas or migrations, you must use these exact types. Never use `VARCHAR` for statuses or roles. Do not invent new enum values without explicit architectural permission.

> ⚠️ **CRITICAL WARNING: ENUM RIGIDITY** ⚠️
> PostgreSQL ENUM values are immutable in production. Removing or renaming an ENUM value requires complex, multi-step migrations and can lock production tables, causing system downtime. All ENUM changes must be carefully planned, reviewed, and execute strictly via the 'Safe ENUM Migration Strategy' outlined at the bottom of this document.

---

## 1. The Core Enums

```sql
-- Identity & Access
CREATE TYPE user_role AS ENUM (
    'undergraduate', 
    'lecturer', 
    'merchant', 
    'admin'
);

-- Financial Vault Types
CREATE TYPE wallet_type AS ENUM (
    'personal',       -- Covers undergrads, lecturers, and staff
    'merchant',       -- Canteens, print shops, bookstores
    'system'          -- Used exclusively by the Master Admin account for minting/top-ups
    'suspense'        -- NEW: Holding account for orphaned/rejected funds
);

-- Wallet Lifecycle
CREATE TYPE wallet_status AS ENUM (
    'active', 
    'frozen',         -- Security lock (temporary). Transactions rejected.
    'closed'          -- Terminal state (e.g., graduated/left university). Transactions rejected.
);

-- The Event Ledger (What happened?)
CREATE TYPE transaction_type AS ENUM (
    'purchase',            -- User pays any merchant (canteen, bookstore, etc.)
    'preorder',       -- users preoder from the canteen when they preorder
    'p2p_transfer',        -- Student-to-Student or Staff-to-Student transfers
    'bank_topup',          -- Money enters personal wallet via bank/gateway
    'merchant_settlement', -- Nightly sweep to merchant's real-world bank account
    'refund'              -- Reversal of a previous payment (Merchant to user, a feature that merchants have)
    'admin_adjustment'         -- admin can put money to any wallet from his wallet and also take money from any wallet that is closed
);

-- The Event Lifecycle (What state is it in?)
CREATE TYPE transaction_status AS ENUM (
    'pending',   -- Waiting for async webhook (e.g., Bank Top-Ups)
    'completed', -- Money successfully moved in the ledger
    'failed'     -- Rejected (Insufficient funds, frozen wallet, gateway decline)
);

-- Ledger Math
CREATE TYPE ledger_direction AS ENUM (
    'debit',
    'credit'
);