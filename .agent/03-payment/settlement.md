# UniPay — Merchant Settlement Flow

> **AI Instruction**: This file outlines the automated and manual processes for sweeping digital funds from a Merchant's UniPay wallet into their verified, real-world bank account. This process must strictly enforce atomic database locks to prevent double-payouts.

---

## 1. The Settlement Philosophy

When a student pays a canteen, the money doesn't instantly move between real bank accounts. Instead:
1. The student's digital balance goes down.
2. The canteen's digital balance goes up.
3. The physical money remains in the **University Master Trust Account**.

**Settlement** is the act of taking the canteen's accumulated digital balance (e.g., at the end of the day) and doing a real-world CEFT/SLIPS bank transfer from the Master Trust Account to the canteen's business bank account.

---

## 2. The Automated Cron Flow (T+1 Settlement)

To minimize transaction fees and manual accounting, UniPay operates on a **T+1 (Transaction + 1 Day)** automated settlement schedule. 

Every night at **11:59 PM Sri Lanka Time**, a Cloudflare Worker Cron Job (`Scheduled Event`) wakes up and executes the following:

### Step 1: The Sweep Query
The Worker asks the database for all verified merchants with a balance greater than 1,000 LKR.
```sql
SELECT m.merchant_id, w.id AS wallet_id, w.balance_cents, mba.account_number, mba.bank_name
FROM merchant_bank_accounts mba
JOIN wallets w ON mba.merchant_id = w.user_id
WHERE mba.is_verified = TRUE 
  AND mba.is_primary = TRUE 
  AND w.balance_cents >= 100000; -- Minimum 1,000 LKR