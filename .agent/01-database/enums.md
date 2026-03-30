# UniPay — Database Enum Reference

> **AI Instruction**: When writing any SQL or TypeScript that references
> a status, role, type, or direction — always use the exact enum values
> defined here. Never use raw strings like 'student' or 'active' without
> verifying they exist in the correct enum. Never use VARCHAR for a column
> that has a fixed set of allowed values.

---

## Critical Warning — Enum Immutability

PostgreSQL ENUM values are immutable once created. This is not a limitation
to work around — it is a feature that enforces data integrity. The consequence
is that changing an enum requires careful planning.

```
SAFE   — Adding a new value:   ALTER TYPE enum_name ADD VALUE 'new_value';
                                No table lock. No downtime. Runs instantly.

UNSAFE — Removing a value:     Requires creating a new enum type, migrating
                                all columns, dropping the old type.
                                Requires a maintenance window.
                                Can lock tables on large datasets.

UNSAFE — Renaming a value:     No shortcut exists. Treat as a remove + add.
                                Requires a maintenance window.
```

**Before adding any enum value**: confirm it is needed in v1.
**Before removing any enum value**: read the Safe Migration Strategy
at the bottom of this file.

The TypeScript constants in `shared/constants/` mirror these enums exactly.
When this file changes, `shared/constants/roles.ts`, `networks.ts`, and
`limits.ts` must be updated in the same commit.

---

## 1. `user_role`

Controls what a user can do in the system. Checked by role middleware
in the Worker and used for role-based UI routing in the frontend.

| Value | Who | Wallet | Creates sheets | Marks attendance | Admin access |
|---|---|---|---|---|---|
| `undergraduate` | Campus students | Yes | Yes | Yes (with index) | No |
| `lecturer` | Academic staff | No | Yes | Yes (with index) | No |
| `merchant` | Canteen/shop owners | Yes (merchant type) | Yes | Yes (with index) | No |
| `admin` | UniPay technical team | Yes (system type) | Yes | Yes (with index) | Yes |

**Attendance marking rule**: Any user can mark attendance regardless of role,
provided their `users.university_index` field is not null. Role is not the
gate — the index number is.

---

## 2. `user_status`

Lifecycle state of a user account.

| Value | Meaning | Can log in | Transactions |
|---|---|---|---|
| `active` | Normal operating state | Yes | Yes |
| `suspended` | Temporarily blocked by admin | No — 403 on session exchange | Rejected |
| `graduated` | Student has left university | Yes — read only | No new payments |

`graduated` is set by the admin team at the end of each academic year.
It does not block login — a graduated student can still view their
transaction history. It blocks new payments only.

---

## 3. `wallet_type`

What kind of wallet this is. Determines the accounting rules applied
to this wallet in the ledger.

| Value | Owner | Debited when | Credited when |
|---|---|---|---|
| `undergraduate` | Student | Makes a payment | Receives a bank topup or refund |
| `merchant` | Canteen/shop | Nightly settlement | Receives a student payment |
| `system` | Admin (Master Trust boundary) | Student tops up via VAN | Merchant is settled |
| `suspense` | Admin (disputed funds) | Disputed funds resolved | Orphaned deposit arrives |

**The `system` wallet invariant**: In a perfectly reconciled system,
the system wallet balance should equal zero. Debit (topup) and credit
(settlement) cancel each other out over time. A non-zero system wallet
balance signals an unreconciled discrepancy requiring investigation.

**The `suspense` wallet**: Receives funds when a deposit cannot be
attributed to any active student wallet (e.g. a VAN that was recycled
but received a deposit before KV propagation confirmed the new owner).
Admin must manually resolve suspense funds — either crediting the
correct student wallet or initiating a bank return.

---

## 4. `wallet_status`

Lifecycle state of a wallet.

| Value | New transactions | Balance visible | Notes |
|---|---|---|---|
| `active` | Accepted | Yes | Normal state |
| `frozen` | Rejected — 403 | Yes | Security lock — admin can unfreeze |
| `closed` | Rejected — 403 | Yes | Terminal — admin can reclaim balance |

A `closed` wallet belongs to a graduated or departed student. The
`admin_adjustment` transaction type is the only way to move money out
of a closed wallet — it requires admin role and a mandatory reason field.

---

## 5. `transaction_type`

What kind of financial event this row represents.

| Value | Direction | Payer | Payee | Created by |
|---|---|---|---|---|
| `purchase` | Student → Merchant | Student wallet | Merchant wallet | `process_payment()` |
| `preorder` | Student → Merchant | Student wallet | Merchant wallet | `process_payment()` |
| `bank_topup` | System → Student | System wallet | Student wallet | `process_bank_topup()` |
| `merchant_settlement` | Merchant → System | Merchant wallet | System wallet | `process_settlement()` |
| `refund` | Merchant → Student | Merchant wallet | Student wallet | `process_payment()` with refund type |
| `admin_adjustment` | Any → Any | Admin wallet | Target wallet | Admin dashboard only |
| `p2p_transfer` | User → User | Any wallet | Any wallet | Pending v1 architectural decision |

**`p2p_transfer` status**: This value exists in the enum but is not
implemented in v1. The feature is pending a final architectural decision.
Do not write code paths for `p2p_transfer` until explicitly instructed.
See `11-features-roadmap/group-splitting.md`.

**`refund` constraint**: The refund amount must not exceed the original
purchase amount. Partial refunds are allowed. Over-refunds are rejected
by `process_payment()` with `UNIPAY_ERR_REFUND_EXCEEDS_ORIGINAL`.

---

## 6. `transaction_status`

Lifecycle state of a transaction row.

| Value | Meaning | Final state? |
|---|---|---|
| `pending` | Awaiting async confirmation | No — transitions to completed or failed |
| `completed` | Money moved successfully | Yes — immutable |
| `failed` | Rejected before money moved | Yes — immutable |
| `reversed` | Deliberately undone after completion | Yes — immutable |
| `disputed` | Under admin review | No — transitions to completed or reversed |

`pending` is used for bank topups while waiting for the webhook.
All other transaction types are written as `completed` directly — they
use synchronous stored functions that either succeed or raise an exception.

A transaction transitions from `disputed` to `completed` when admin
confirms the payment stands, or to `reversed` when admin confirms it
must be undone. Both transitions create new ledger entries.

---

## 7. `ledger_direction`

The direction of money flow for a single ledger entry.

| Value | Effect on balance | Used when |
|---|---|---|
| `debit` | Balance decreases | Money leaving a wallet |
| `credit` | Balance increases | Money entering a wallet |

Every transaction produces exactly two ledger entries: one debit and
one credit of equal `amount_cents`. The sum of all ledger entries for
any transaction is always zero.

Do not confuse with everyday banking language ("your account has been
credited" sometimes means different things). In UniPay's ledger, debit
always means decrease, credit always means increase.

---

## 8. `van_status`

Lifecycle state of a Virtual Account Number.

| Value | Accepts deposits | Assigned to student | Notes |
|---|---|---|---|
| `available` | N/A | No | In the pool — ready for JIT allocation |
| `assigned` | Yes — credited to student | Yes | Live and operational |
| `quarantined` | Bounced to sender | No (student graduated) | 6 months after `deactivated_at` |
| `eligible_for_recycle` | Still bounced | No | 18 months after `deactivated_at` — ready to reassign |

The `quarantined` → `eligible_for_recycle` → `available` transitions
are handled by the `vanReclaim.ts` cron job at 02:00 LKT daily.

---

## 9. `session_status`

Lifecycle state of an attendance sheet.

| Value | Code valid | Submissions accepted | Notes |
|---|---|---|---|
| `active` | Yes | Yes | Timer is running |
| `expired` | No | No | Timer ran out — `close_sheet()` called by cron |
| `closed` | No | No | Creator clicked Close Early |

Both `expired` and `closed` trigger the Excel export automatically.
The difference is only in how the session ended — it has no effect
on the attendance records or the export contents.

---

## 10. `network_type`

Classification of the network a student was on when they submitted
their attendance code. Determined by the Worker based on the
submitted IP address.

| Value | Network | Trust level | Attendance status assigned |
|---|---|---|---|
| `eduroam` | Campus Wi-Fi | Trusted | `present` |
| `cellular_dialog` | Dialog mobile | Flagged | `pending_network_verification` |
| `cellular_mobitel` | Mobitel mobile | Flagged | `pending_network_verification` |
| `unknown` | Unclassified IP | Flagged | `pending_network_verification` |

IP classification happens in `worker/src/utils/network.ts`. The IP ranges
for Dialog and Mobitel are maintained as environment variables and updated
when carriers change their allocations.

Flagged submissions are NOT automatically marked absent. They appear in
the lecturer's dashboard with an amber flag for manual review. The lecturer
decides whether to accept or reject each flagged submission.

---

## 11. `attendance_status`

The final status of a student's attendance for a given session.

| Value | Meaning | Created by |
|---|---|---|
| `present` | Submitted on Eduroam within window | `mark_attendance()` |
| `pending_network_verification` | Submitted on cellular — needs review | `mark_attendance()` |
| `manually_added` | Added by sheet creator after closing | `manual_add_attendance()` |
| `absent` | Did not submit — recorded on close | `close_sheet()` |

`absent` records are only created for sessions that use module enrollment
tracking. For open sessions (anyone with the code can mark), absent is
simply represented by the absence of a row.

---

## 12. `submission_outcome`

Logged for every code submission attempt — successful or not. Used for
fraud detection and audit trail. Stored in `submission_attempts` table.

| Value | Meaning | Creates attendance_record? |
|---|---|---|
| `success` | Code valid, session active, not duplicate | Yes |
| `wrong_code` | Code does not match any active session | No |
| `expired` | Code matched but session window closed | No |
| `duplicate` | Student already marked for this session | No |
| `no_index_number` | User has no `university_index` on their profile | No |

All five outcomes are logged. This means the `submission_attempts` table
captures failed attempts that would otherwise be invisible. A student with
ten `wrong_code` attempts followed by one `success` is visible in the
fraud audit log even though their attendance record shows `present`.

---

## 13. `sku_category`

Product category for merchant menu items. Used for analytics grouping
in the demand forecast and for the SKU management dashboard filter.

| Value | Examples |
|---|---|
| `meal` | Rice and curry, kottu, string hoppers, sandwiches |
| `beverage` | Plain tea, Milo, juice, water bottles |
| `snack` | Short eats, biscuits, fruit, yoghurt |
| `stationery` | Pens, notebooks, printing (non-food merchants) |
| `other` | Anything that does not fit the above |

---

## 14. `rush_period`

The three daily time bands used by the Campus Pulse scoring system.
Scores reset at the start of each period.

| Value | LKT window | Score resets at | Cron trigger |
|---|---|---|---|
| `morning` | 06:00 – 12:00 | 06:00 LKT | `refreshTrafficScore.ts` |
| `lunch` | 12:00 – 18:00 | 12:00 LKT | `refreshTrafficScore.ts` |
| `dinner` | 18:00 – 06:00 | 18:00 LKT | `refreshTrafficScore.ts` |

---

## 15. `notification_type`

Type of in-app notification. Used by the frontend to choose the correct
icon, color, and action when a notification is tapped.

| Value | Recipient | Trigger |
|---|---|---|
| `payment_received` | Merchant | Student completes a payment |
| `payment_sent` | Student | Payment completes successfully |
| `topup_credited` | Student | Bank webhook received and credited |
| `settlement_complete` | Merchant | Nightly settlement succeeds |
| `settlement_failed` | Admin | Nightly settlement fails for a merchant |
| `attendance_confirmed` | Student | Attendance marked successfully |
| `van_quarantined` | Admin | VAN moves to quarantined status |
| `low_van_pool` | Admin | Available VAN count drops below 200 |

---

## Safe ENUM Migration Strategy

### Adding a value (safe — no downtime)

```sql
-- Safe to run in production with zero downtime
-- No table lock, no data migration required
ALTER TYPE transaction_type ADD VALUE 'new_value' AFTER 'existing_value';

-- Then create a migration file:
-- database/migrations/YYYYMMDD_NNN_add_new_value_to_transaction_type.sql
```

### Removing a value (unsafe — requires maintenance window)

```sql
-- Step 1: Verify no rows use the value being removed
SELECT COUNT(*) FROM transactions WHERE type = 'value_to_remove';
-- Must return 0 before proceeding

-- Step 2: Create a new enum without the value
CREATE TYPE transaction_type_new AS ENUM (
  'purchase', 'preorder', 'bank_topup' -- all values EXCEPT the removed one
);

-- Step 3: Migrate all columns using the old enum
ALTER TABLE transactions
  ALTER COLUMN type TYPE transaction_type_new
  USING type::text::transaction_type_new;

-- Step 4: Drop old enum, rename new one
DROP TYPE transaction_type;
ALTER TYPE transaction_type_new RENAME TO transaction_type;

-- Step 5: Update shared/constants/ to remove the value
-- Step 6: Deploy Worker and frontend before running this migration
```

### Renaming a value (unsafe — treat as remove + add)

There is no `ALTER TYPE RENAME VALUE` that renames cleanly.
The only safe approach is: add the new value, migrate all rows to use
the new value, then remove the old value following the steps above.
This is a three-migration process that requires careful coordination.