# UniPay — Payment System Overview

> **AI Instruction**: Read this file before writing any payment-related code.
> Every statement here is a final architectural decision. Do not suggest
> alternative funding mechanisms, withdrawal features, or peer-to-peer
> transfers. These are explicitly out of scope for v1.

---

## What Kind of Payment System This Is

UniPay is a **closed-loop digital voucher system**. It is not a bank. It is
not a payment gateway. It is not a wallet that can send money to the outside
world. It is a ledger that tracks voucher balances within a single campus
ecosystem.

The analogy is a prepaid canteen card — a student loads money onto it, spends
it at campus vendors, and the balance lives inside the system. The difference
is that UniPay does this digitally, in real time, at sub-1.5 second speed,
with full SKU-level transaction history feeding a merchant analytics engine.

---

## The Master Trust Model

Real fiat currency never moves when a student pays a merchant. Only a number
in a database changes. Here is where the real money actually lives:

```
Parent → Bank Transfer → Partner Bank (HNB / Seylan) Master Trust Account
                                    ↓
                         UniPay credits student wallet (database row)
                                    ↓
                    Student pays Merchant (two database rows update)
                                    ↓
                    Nightly settlement sweeps merchant balance
                                    ↓
                         Partner Bank → Merchant's real bank account
```

The Master Trust account is a single pooled bank account held in the partner
bank's name. At any point in time, the total of all wallet balances in UniPay's
database must equal the total balance of the Master Trust account. This is the
fundamental financial integrity invariant of the system.

**UniPay's role**: technology and ledger layer only. The bank holds the money.
UniPay holds the record of who is entitled to how much of it.

---

## The One Way Money Enters UniPay

There is exactly one funding mechanism:

**Bank Transfer via Virtual Account Number (VAN)**

A parent or student transfers money from any Sri Lankan bank account to the
student's assigned VAN number. This is a standard internet banking transfer —
the parent needs no app, no registration, no digital literacy beyond knowing
how to do an online transfer.

The VAN is a real bank account number issued by the partner bank under the
Master Trust structure. When money arrives at that VAN, the bank fires a
webhook to the UniPay Worker, which credits the student's wallet in real time.

There is no card top-up. There is no cash deposit. There is no PayHere or
any other IPG. UniPay is completely outside PCI-DSS scope because it never
touches card data under any circumstance.

---

## The Three Ways Money Moves Inside UniPay

Once inside the system, money moves in three ways only:

### 1. Student → Merchant (Purchase)
A student scans a merchant's QR code and pays for goods or services. The
student's `balance_cents` decreases. The merchant's `balance_cents` increases.
Both changes happen atomically in a single PostgreSQL transaction via the
`process_payment()` stored function. If either update fails, both are rolled
back. No partial state is possible.

### 2. Admin Adjustment
An administrator can credit or debit any wallet for legitimate operational
reasons — correcting a failed settlement, issuing a goodwill credit, or
resolving a dispute. Every admin adjustment requires a `reason` field and is
logged in the audit trail. Admin adjustments cannot be performed from the
student or merchant interface — only from the admin dashboard by a user with
`role = 'admin'`.

### 3. Merchant → Bank (Nightly Settlement)
At 01:00 LKT every night, the `nightlySettlement.ts` cron job sweeps all
merchant wallet balances to their registered physical bank accounts via the
partner bank's settlement API. After a successful sweep, the merchant's
`balance_cents` is set to zero and a `merchant_settlement` transaction is
inserted as the audit record.

---

## The One Way Money Leaves UniPay

**Nightly merchant settlement is the only outbound money flow.**

Students cannot withdraw their balance to a bank account. There are no refunds
to the original bank transfer. There are no peer-to-peer transfers between
students. If a student leaves the university with a remaining balance, the
balance is handled as an operational matter by the admin team — it does not
leave the system automatically.

This constraint is intentional and is what keeps UniPay a closed-loop system.
A closed loop is dramatically simpler to operate, audit, and keep compliant
than an open system that must handle outbound transfers.

---

## What UniPay Is Not Responsible For

The following are explicitly outside UniPay's scope and must never be built
into the payment module without a formal architectural decision:

| Not in scope | Reason |
|---|---|
| Card payments | No IPG — PCI-DSS out of scope by design |
| Student withdrawals | Open-loop feature — not in v1 |
| Peer-to-peer transfers | Not in v1 — see `11-features-roadmap/group-splitting.md` |
| Refunds to bank account | Not supported — admin adjustment is the resolution path |
| International transfers | Not applicable — campus-only system |
| Crypto or digital currency | Not applicable |
| Merchant-to-merchant transfers | Not applicable |

---

## Financial Integrity Rules

These rules must never be violated by any code in any module:

```
RULE 1: The sum of all wallet balance_cents must always equal the
        Master Trust account balance at the partner bank.

RULE 2: balance_cents is always BIGINT cents (integer).
        1 LKR = 100 cents. Never DECIMAL, never FLOAT, never string.

RULE 3: balance_cents can never go below zero.
        Enforced by: CHECK (balance_cents >= 0) on the wallets table.
        The database rejects overdrafts — the Worker does not pre-check.

RULE 4: Every balance change creates exactly two ledger entries:
        one debit and one credit. The ledger is always balanced.

RULE 5: The transactions table is append-only.
        Never UPDATE or DELETE a transaction row.
        Reversals are new rows with type = 'refund'.

RULE 6: process_payment() is the only function that moves money
        between student and merchant wallets.
        The Worker never issues raw UPDATE queries against wallets.

RULE 7: Every transaction has a unique idempotency_key.
        Duplicate keys return the original result — never charge twice.
```

---

## Performance Target

The payment flow must complete end-to-end in **under 1.5 seconds** during
peak load (500 concurrent users at the 12:30 PM canteen rush).

This target is achieved by:
- A single atomic DB function call (`process_payment()`) — one round trip
- No pre-flight balance check in the Worker — the DB enforces the floor
- No step-up authentication — session cookie is the only auth
- No PIN, no confirmation screen — scan and pay
- Cloudflare Workers at the edge — sub-50ms API response time
- Neon serverless PostgreSQL — connection pooling, no cold start

The 1.5 second target covers: network (student device → Cloudflare edge) +
Worker execution + database round trip + response + merchant notification.

---

## Transaction Types Reference

Defined in `database/schemas/enums.sql` as `transaction_type`:

| Type | Direction | Description |
|---|---|---|
| `purchase` | Student → Merchant | Standard QR payment at a campus vendor |
| `preoder` | Student → Merchant | Student pays in advance from lecture hall or off-campus before arriving at the canteen |
| `p2p_transfer` | Any wallet → Any wallet | Student-to-student or staff-to-student direct transfer |
| `bank_topup` | VAN → Student wallet | Parent bank transfer credited to student |
| `merchant_settlement` | Merchant wallet → Bank | Nightly sweep to merchant's bank account |
| `refund` | Merchant → Student | Reversal of a previous purchase |
| `admin_adjustment` | Admin → Any wallet |Any wallet → Admin own wallet| Manual correction by admin team |

---

## Related Files

- `03-payment/payment-flow.md` — step-by-step QR payment sequence
- `03-payment/process-payment-fn.md` — the stored function explained
- `03-payment/idempotency.md` — double charge prevention
- `03-payment/ledger.md` — double-entry accounting
- `03-payment/topup-van.md` — the VAN funding mechanism
- `03-payment/settlement.md` — nightly merchant settlement
- `01-database/functions.md` — all stored functions
- `00-system/security-rules.md` — financial security rules