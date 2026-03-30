# UniPay — Seed Data Reference

> **AI Instruction**: Seed data exists for development and staging only.
> Never load seed files against the production database. The seed files
> create predictable, known test users and data so any developer can
> start working immediately without manual setup.

---

## 1. Warning — Never Run Against Production

```
⛔ SEED DATA IS FOR DEVELOPMENT AND STAGING ONLY

The seed files:
  - Delete and recreate all test users
  - Set wallet balances to fixed test amounts
  - Create fake transactions and attendance records

Running seed files against production would:
  - Corrupt real student wallet balances
  - Create fake transactions in the immutable ledger
  - Compromise the Master Trust reconciliation

The migrate.sh script refuses to run seed files against
the production branch. Never bypass this check.
```

---

## 2. Seed Files and Load Order

Load in this exact order — foreign key dependencies require it:

```bash
# From the project root:
psql $DATABASE_URL -f database/seed/seed_users.sql
psql $DATABASE_URL -f database/seed/seed_wallets.sql
psql $DATABASE_URL -f database/seed/seed_merchants.sql
psql $DATABASE_URL -f database/seed/seed_attendance.sql
```

Or use the convenience script:
```bash
./infrastructure/scripts/migrate.sh seed dev
```

---

## 3. Test Users

All test users use Google OAuth in the test Firebase project.
Email/password login is also available with the passwords below.

### Undergraduate Students

| Name | Email | Password | University Index | Batch | Balance |
|---|---|---|---|---|---|
| Navod Caldera | navod@stu.mrt.ac.lk | Test1234! | 230001A | 2023 | LKR 5,000.00 |
| Amara Perera | amara@stu.mrt.ac.lk | Test1234! | 230002B | 2023 | LKR 2,500.00 |
| Kasun Silva | kasun@stu.mrt.ac.lk | Test1234! | 220001C | 2022 | LKR 150.00 |
| Dilini Fernando | dilini@stu.mrt.ac.lk | Test1234! | 230003D | 2023 | LKR 0.00 |
| Ruwan Jayawardena | ruwan@stu.mrt.ac.lk | Test1234! | 220002E | 2022 | LKR 12,000.00 |

Kasun (LKR 150.00) is useful for testing near-insufficient-funds payments.
Dilini (LKR 0.00) is useful for testing insufficient funds rejection.

### Lecturers

| Name | Email | Password | University Index | Notes |
|---|---|---|---|---|
| Dr. Sampath Wijesinghe | sampath@lec.mrt.ac.lk | Test1234! | NULL | Main test lecturer |
| Prof. Nimal Gunasekara | nimal@lec.mrt.ac.lk | Test1234! | NULL | Second lecturer |
| Ms. Rukmali Dias | rukmali@lec.mrt.ac.lk | Test1234! | 199901F | Has index — can mark attendance |

Ms. Rukmali has a university_index to test the edge case where a
lecturer also has an index number and can mark attendance.

### Merchants

| Name | Email | Password | Business | Location |
|---|---|---|---|---|
| Goda Bandara | goda@merchant.unipay.lk | Test1234! | Goda Canteen | Main Canteen, Block A |
| Priya Stores | priya@merchant.unipay.lk | Test1234! | Priya Stationery | Block B, Ground Floor |

### Admin

| Name | Email | Password | Notes |
|---|---|---|---|
| UniPay Admin | admin@unipay.lk | Admin1234! | Full system access |

---

## 4. Goda Canteen SKU Catalogue

The main test merchant has a realistic menu:

| SKU | Category | Price (LKR) | Available |
|---|---|---|---|
| Rice and Curry | meal | 250.00 | Yes |
| String Hoppers | meal | 180.00 | Yes |
| Kottu Roti | meal | 350.00 | Yes |
| Plain Tea | beverage | 30.00 | Yes |
| Milo | beverage | 60.00 | Yes |
| Juice (Orange) | beverage | 80.00 | Yes |
| Egg Roti | snack | 100.00 | Yes |
| Fish Cutlet | snack | 70.00 | Yes |
| Biscuit Packet | snack | 50.00 | No (sold out — tests unavailable SKU) |

Priya Stationery has stationery SKUs:

| SKU | Category | Price (LKR) | Available |
|---|---|---|---|
| A4 Pad (80 pages) | stationery | 250.00 | Yes |
| Ball Point Pen | stationery | 35.00 | Yes |
| Highlighter Set | stationery | 180.00 | Yes |
| Photocopy (per page) | stationery | 5.00 | Yes |

---

## 5. Pre-Seeded Transactions

The seed creates a realistic transaction history for testing:

**Navod's transaction history (5 transactions):**
```
+500000  bank_topup   — "Bank Transfer (VAN)" — yesterday
- 25000  purchase     — "Goda Canteen" — this morning (Rice and Curry)
-  3000  purchase     — "Goda Canteen" — this morning (Plain Tea)
- 65000  preorder     — "Goda Canteen" — today at 10:30 (Kottu Roti)
- 25000  purchase     — "Goda Canteen" — 3 days ago
Current balance: 500000 - 25000 - 3000 - 65000 - 25000 = 382000 cents = LKR 3,820.00
```

Wait — the seed.sql balance is set to 500000 cents (LKR 5,000.00) for
simplicity. The transaction history rows exist for display testing but
the balance is set directly rather than computed from the transactions.
This is a seed shortcut — never do this in production code.

**Goda Canteen's wallet:**
Balance is set to LKR 8,500.00 to simulate an unsettled day's revenue
before the nightly settlement cron runs.

---

## 6. Pre-Seeded Attendance Sheets

Four sheets in different states for testing every UI state:

| Sheet | Module | Status | Marks | Notes |
|---|---|---|---|---|
| Active sheet | CS3012 — Machine Learning | `active` | 3 | Code valid for 5 minutes from seed load time |
| Expired sheet | EE2012 — Circuits | `expired` | 45 | Just expired — Excel ready |
| Closed sheet | CS2032 — Data Structures | `closed` | 120 | Manually closed — Excel ready |
| Zero-mark sheet | MA1013 — Calculus | `expired` | 0 | Nobody marked — tests empty state |

**Active sheet code**: `ABCDE`
This is a hardcoded test code for the active sheet. It expires 5 minutes
after the seed script runs. Use it to test the student marking flow
immediately after running seed.

The active sheet has three students already marked:
- Navod Caldera (230001A) — eduroam — not flagged
- Amara Perera (230002B) — cellular_dialog — flagged
- Kasun Silva (220001C) — eduroam — not flagged

---

## 7. VANs

Ten VANs are seeded in various states:

| VAN Number | Status | Assigned to |
|---|---|---|
| 0789-4521-0034-001 | assigned | Navod Caldera |
| 0789-4521-0034-002 | assigned | Amara Perera |
| 0789-4521-0034-003 | assigned | Kasun Silva |
| 0789-4521-0034-004 | assigned | Dilini Fernando |
| 0789-4521-0034-005 | assigned | Ruwan Jayawardena |
| 0789-4521-0034-006 | available | — |
| 0789-4521-0034-007 | available | — |
| 0789-4521-0034-008 | available | — |
| 0789-4521-0034-009 | quarantined | — |
| 0789-4521-0034-010 | eligible_for_recycle | — |

The quarantined and eligible VANs test the admin VAN pool dashboard.

---

## 8. Resetting to Clean State

To completely reset the development database to a fresh seed state:

```bash
# Drop all tables and recreate from scratch
./infrastructure/scripts/migrate.sh reset dev

# This runs:
# 1. DROP all tables (CASCADE)
# 2. All migration files in order
# 3. All seed files in order

# WARNING: This destroys ALL data in the dev branch
# Never run against staging or production
```

To reset just the seed data without re-running migrations:

```bash
./infrastructure/scripts/migrate.sh seed dev --reset
```

This runs `TRUNCATE ... CASCADE` on all tables and re-inserts seed rows.
Faster than a full reset — migrations are not re-run.