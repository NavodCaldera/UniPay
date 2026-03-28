# UniPay — Database Views

> **AI Instruction**: This file defines the PostgreSQL Views used to abstract complex ledger joins away from the Cloudflare Worker. The API must query these views instead of writing complex joins in TypeScript.

---

## 1. The Philosophy of Views
Because UniPay uses a strict Double-Entry Ledger (`transaction_events` + 2x `ledger_entries`), reconstructing a simple "Receipt" or "History Timeline" for a user requires joining multiple tables to find the "counterparty" (e.g., if I am the Debit, who is the Credit?). 

Views keep the Edge API lightweight. All heavy joining and formatting happens natively in PostgreSQL.

---

## 2. Core Views

### View: `user_transaction_history`
*Purpose: Provides a clean, chronological timeline of a user's wallet activity, automatically resolving the name of the person/canteen they interacted with.*

```sql
CREATE OR REPLACE VIEW user_transaction_history AS
SELECT 
    le.id AS ledger_entry_id,
    te.id AS transaction_event_id,
    w.user_id AS owner_user_id,
    te.created_at AS timestamp,
    te.type AS transaction_type,
    te.status AS transaction_status,
    
    -- Financials
    le.amount_cents,
    le.direction, -- 'debit' or 'credit'
    
    -- UI Helper: Formats cents to a standard decimal string (e.g., 500.00)
    TRIM(TRAILING '.' FROM (le.amount_cents::numeric / 100)::text) AS display_amount,

    -- Scale-Optimized Counterparty Resolution
    -- Uses a LATERAL join to find exactly one name per ledger entry without
    -- exploding the join buffer for 30,000+ users.
    cp.counterparty_name,
    cp.counterparty_role,
    
    -- Metadata extraction for fast API access
    te.metadata->>'bank_ref' AS bank_reference,
    te.metadata->>'note' AS user_note,
    te.metadata
FROM ledger_entries le
JOIN transaction_events te ON le.transaction_event_id = te.id
JOIN wallets w ON le.wallet_id = w.id
LEFT JOIN LATERAL (
    -- Finds the "Other Side" of the transaction.
    -- If there are multiple parties (e.g., a fee), it picks the one 
    -- with the largest money movement (the main recipient/payer).
    SELECT 
        u.full_name AS counterparty_name,
        u.role AS counterparty_role
    FROM ledger_entries side_le
    JOIN wallets side_w ON side_le.wallet_id = side_w.id
    JOIN users u ON side_w.user_id = u.id
    WHERE side_le.transaction_event_id = te.id 
      AND side_le.wallet_id != le.wallet_id
    ORDER BY ABS(side_le.amount_cents) DESC
    LIMIT 1
) cp ON TRUE;