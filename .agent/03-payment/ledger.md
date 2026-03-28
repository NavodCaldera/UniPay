# UniPay — The Double-Entry Ledger System

> **AI Instruction**: This file explains the core accounting principles used in UniPay. Developers must understand the difference between `transaction_events` and `ledger_entries` before building UI components or writing balance queries.

---

## 1. What is Double-Entry?

UniPay uses a strict **Double-Entry Bookkeeping** system. This means money is never "created" or "destroyed"—it only moves from one wallet to another. 

Every single financial action (an **Event**) produces exactly **two** rows in the ledger:
1. A **Debit** (Money leaving a wallet, stored as a negative number).
2. A **Credit** (Money arriving in a wallet, stored as a positive number).

**The Golden Rule of UniPay:**
If you take a `transaction_event_id` and sum up the `amount_cents` of its connected `ledger_entries`, the result must **always equal zero**. If it doesn't, the database throws a critical exception and rolls back the payment.

---

## 2. Terminology & Data Types

* **Cents, Not Rupees:** We never use decimals (`double` or `float`) to store money. A balance of Rs. 500.50 is stored as an integer: `50050`. This prevents rounding errors in JavaScript and PostgreSQL.
* **Transaction Event (`transaction_events`):** The "Receipt." It holds the timestamp, the type of transaction (purchase, topup, settlement), and the idempotency key. It does *not* hold the amount.
* **Ledger Entry (`ledger_entries`):** The "Math." It holds the specific wallet ID, the direction (debit/credit), and the exact amount in cents.

---

## 3. Standard Transaction Examples

Here is how the ledger looks for the three most common actions in the system.

### A. The P2P Transfer or Canteen Purchase
*Navod (Wallet A) buys a 500 LKR lunch from Main Canteen (Wallet B).*

**Event:** `type: 'purchase'`
**Ledger:**
| Wallet | Direction | Amount (Cents) | Effect on Balance |
| :--- | :--- | :--- | :--- |
| Navod (A) | `debit` | `-50000` | Balance decreases by 500.00 |
| Canteen (B) | `credit` | `50000` | Balance increases by 500.00 |

### B. The VAN Bank Top-Up
*Navod transfers 5,000 LKR from his BOC App to his UniPay VAN.*

**Event:** `type: 'topup'`
**Ledger:**
| Wallet | Direction | Amount (Cents) | Effect on Balance |
| :--- | :--- | :--- | :--- |
| System Trust | `debit` | `-500000` | Internal tracking balance decreases |
| Navod (A) | `credit` | `500000` | Balance increases by 5,000.00 |

### C. The Nightly Merchant Settlement
*The Main Canteen settles its 100,000 LKR daily revenue to its real-world bank account.*

**Event:** `type: 'settlement'`
**Ledger:**
| Wallet | Direction | Amount (Cents) | Effect on Balance |
| :--- | :--- | :--- | :--- |
| Canteen (B) | `debit` | `-10000000`| Digital balance resets to 0 |
| System Out | `credit` | `10000000` | Triggers API call to real-world bank |

---

## 4. Frontend Developer Guide

When building the SvelteKit UI, you will primarily query the `user_transaction_history` PostgreSQL View, not the raw ledger tables. 

**Rules for the UI:**
1.  **Red vs. Green:** If the view returns `direction: 'debit'`, show the amount in Red with a minus sign (e.g., `- Rs. 500.00`). If `credit`, show it in Green (e.g., `+ Rs. 500.00`).
2.  **Formatting:** Always use the `display_amount` string provided by the view (e.g., `"500.00"`) for text labels. Do not divide `amount_cents` by 100 on the frontend unless you are doing active cart math.
3.  **Counterparty:** The view automatically provides `counterparty_name`. You do not need to fetch the other user's profile.