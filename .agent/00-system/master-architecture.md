# UniPay — Master Architecture

> **AI Instruction**: Read this file at the start of every coding session without
> exception. Every technical decision in this file is final. Do not suggest
> alternatives unless explicitly asked. Do not introduce new libraries,
> patterns, or approaches that contradict what is written here.

---

## What UniPay Is

UniPay is a closed-loop digital voucher and micro-economy platform built
exclusively for university campuses. It is not a general-purpose payment app.
It operates within a single campus ecosystem where real fiat currency is held
by a partner bank (HNB or Seylan) in a Master Trust account, and UniPay acts
purely as the technology and ledger layer.

**The single most important architectural rule:**
UniPay never holds real money. It only moves voucher balances between rows
in a PostgreSQL database. Real fiat moves only twice: inbound when a parent
bank-transfers to a VAN, and outbound during nightly merchant settlement.

---

## The Four User Roles

Every piece of code in this system is written for one of these four roles.
They map exactly to the `user_role` enum in the database.

| Role | Enum value | Who they are | Primary interface |
|---|---|---|---|
| Undergraduate | `undergraduate` | Campus students | PWA mobile |
| Lecturer | `lecturer` | Academic staff | PWA web/tablet |
| Merchant | `merchant` | Canteen/shop owners | PWA tablet |
| Admin | `admin` | UniPay technical team | Internal dashboard |

**Permission rule for attendance:**
- Any user can CREATE an attendance sheet
- Only users with `university_index` filled in their profile can MARK attendance
- Only the sheet CREATOR can manually add students after the sheet closes

**Permission rule for payments:**
- Only `undergraduate` users have wallets and can make payments
- Only `merchant` users can receive payments

---

## Tech Stack — Final, Non-Negotiable

### Frontend
- **Framework**: SvelteKit 5 (not SvelteKit 4, not Next.js, not Nuxt)
- **Reactivity**: Svelte 5 Runes exclusively — no Svelte 4 stores anywhere
- **UI components**: shadcn-svelte
- **Styling**: Tailwind CSS
- **Deployment**: Cloudflare Pages via `@sveltejs/adapter-cloudflare`
- **Type**: Progressive Web App (PWA) with home screen shortcuts

### Backend
- **Runtime**: Cloudflare Workers
- **Framework**: Hono (lightweight, edge-native, TypeScript-first)
- **API**: RESTful, versioned under `/api/v1/`
- **Scheduled jobs**: Cloudflare Workers Cron Triggers

### Database
- **Provider**: Neon (serverless PostgreSQL)
- **Driver**: `@neondatabase/serverless`
- **Schema rules**: strict enums, UUIDs via `gen_random_bytes`, JSONB for receipts
- **Money**: always stored as `BIGINT` cents — never `DECIMAL`, never `FLOAT`

### Authentication
- **Identity provider**: Firebase Auth (Google OAuth + email/password)
- **Session model**: Firebase ID token exchanged for UniPay HttpOnly JWT cookie
- **After login**: Firebase is not involved — Worker verifies its own JWT
- **Storage**: HttpOnly, Secure, SameSite=Strict cookie — never localStorage

### Shared contracts
- **Package**: `shared/` workspace — imported by both `worker/` and `frontend/`
- **Validation**: Zod schemas in `shared/validation/` — single source of truth
- **Types**: TypeScript interfaces in `shared/types/`

---

## Monorepo Structure — Top Level

```
UniPay/
├── .agent/          # AI context files (you are here)
├── shared/          # Shared types and Zod schemas
├── database/        # PostgreSQL schema, functions, migrations, seed
├── worker/          # Cloudflare Workers API (Hono)
├── frontend/        # SvelteKit 5 PWA
├── infrastructure/  # Deployment scripts, env files, wrangler config
└── docs/            # Architecture and API documentation
```

Full folder structure is defined in `.agent/00-system/folder-structure.md`.

---

## Authentication Flow — Summary

1. User signs in via Firebase (Google or email/password) on the frontend.
2. Firebase returns an ID token to the browser.
3. Browser POSTs the ID token to `POST /api/v1/auth/session` on the Worker.
4. Worker verifies the token using lightweight Web Crypto (`jose`) — NEVER use the `firebase-admin` Node.js SDK.
5. Worker verifies `email_verified == true` for password logins.
6. Worker creates a row in `user_sessions` table with a unique `jwt_jti`.
7. Worker mints its own JWT and sets it as a 7-day HttpOnly cookie.
8. Browser never sees or touches the JWT — the cookie is entirely invisible to JavaScript.
9. Every subsequent API call sends the cookie automatically; Worker verifies it via `jose` and checks the KV blocklist for revocation (Firebase is no longer involved).
10. Logout sets `revoked_at` in the database and writes the `jti` to the Cloudflare KV blocklist, instantly invalidating the session at the network edge.

**Email/password accounts**: Worker rejects tokens where `email_verified = false`.
**Lost device**: User logs in on another device, hits `DELETE /api/v1/auth/session/:jti`.

---

## Payment Flow — Summary

The complete spec is in `.agent/03-payment/`. The summary is:

1. Student scans merchant QR code
2. Frontend calls `POST /api/v1/payments` with amount and idempotency key
3. Worker middleware verifies JWT cookie
4. Worker calls `process_payment()` PostgreSQL stored function
5. Function atomically: debits student wallet, credits merchant wallet, inserts transaction row
6. Worker returns success — total round trip target: under 1.5 seconds
7. Both student and merchant receive instant confirmation

**No PIN, no step-up auth, no velocity limits.**
The session cookie is the only authentication. Silent payments always.

---

## Attendance Flow — Summary (Stateless TOTP)

**Creator side (Lecturer):**
1. Fills module code, name, and duration. Worker inserts a row into `attendance_sessions` generating a hidden `session_secret` UUID.
2. Creator's dashboard polls the Worker. The DB calculates a 6-digit PIN on the fly using the `session_secret` + current minute.
3. Creator displays the massive 6-digit PIN, which visually rotates every 60 seconds synced to the system clock.
4. Live roster updates via polling as students mark.

**Student side:**
1. Student enters the 6-digit PIN.
2. Worker passes the PIN to the `verify_attendance_stateless()` PostgreSQL function.
3. The DB mathematically verifies the PIN against the current and previous minute (allowing 60s of drift for slow typing).
4. If it matches, the DB atomically logs the attendance and enforces a unique constraint to prevent double-marking.

---

## The Campus Pulse Score — Summary

The complete spec is in `.agent/05-merchant/traffic-score-equation.md`.

```
T = round( P × 100 )

P = min(
  confirmed_present_in_band / historical_avg_present_same_band,
  1.0
)
```

- Score resets at **06:00**, **12:00**, and **18:00** LKT
- Three bands: Morning (06:00–12:00), Lunch (12:00–18:00), Dinner (18:00–06:00)
- Score is campus-wide — all merchants see the same score
- No machine learning — purely presence ratio
- Computed by `compute_traffic_score()` PostgreSQL function
- Cached in Cloudflare KV, refreshed by cron at each reset window

---

## Database Rules — Non-Negotiable

```
RULE 1: Money is BIGINT cents. 1 LKR = 100 cents. Never DECIMAL or FLOAT.
RULE 2: All primary keys are UUID from gen_random_uuid() (pgcrypto).
RULE 3: All timestamps are TIMESTAMPTZ stored in UTC.
RULE 4: Displayed times are converted to Asia/Colombo (UTC+5:30) at the API layer.
RULE 5: Stored functions are atomic. Never replicate their logic in the Worker.
RULE 6: The transactions table is immutable. No UPDATE or DELETE — only INSERT.
RULE 7: balance_cents has CHECK (balance_cents >= 0). Overdraft is impossible.
RULE 8: Attendance records use present-only model. Absent = no row.
RULE 9: All enums are defined in database/schemas/enums.sql.
RULE 10: Migrations are timestamped and append-only. Never edit after running.
```

---

## Worker Rules — Non-Negotiable

```
RULE 1: All routes are under /api/v1/.
RULE 2: Every protected route runs auth.middleware.ts first.
RULE 3: Attendance mark route also runs capability.middleware.ts (checks university_index).
RULE 4: Never return stack traces to the client. error.middleware.ts handles all errors.
RULE 5: All request bodies are validated via Zod before reaching the controller.
RULE 6: Payment endpoints require an idempotency_key in the request body.
RULE 7: The Worker never calls Firebase after the session exchange — no Firebase dependency at runtime.
RULE 8: Cron jobs live in worker/src/cron/ — never inside a controller.
RULE 9: Side effects (Excel export, audit log) are fired via the internal event bus.
RULE 10: Analytics scores are read from KV cache, not computed on every request.
```

---

## Frontend Rules — Non-Negotiable

```
RULE 1: Never call fetch() directly in a component. Always use lib/api/*.
RULE 2: Never store any token in localStorage or sessionStorage.
RULE 3: Never use Svelte 4 stores. Runes only. State files use .svelte.ts extension.
RULE 4: The (app)/+layout.ts sets ssr = false for all protected routes.
RULE 5: The (auth)/login page keeps ssr = true.
RULE 6: Import Zod schemas from shared/validation/ — never redefine validation locally.
RULE 7: Import TypeScript types from shared/types/ — never redefine types locally.
RULE 8: Role routing uses SvelteKit nested route groups (e.g., `(app)/(undergraduate)/` and `(app)/(lecturer)/`) to enforce strict code splitting. Never use conditional rendering for role-specific layouts on a single page.
RULE 9: Every API error state must have a visible UI response — no silent failures.
RULE 10: The +error.svelte global error boundary must always exist.
```

---

## Shared Package Rules — Non-Negotiable

```
RULE 1: shared/ is the single source of truth for TypeScript types.
RULE 2: shared/ is the single source of truth for Zod validation schemas.
RULE 3: shared/constants/ mirrors database enums exactly — they must stay in sync.
RULE 4: Never put runtime logic in shared/ — types and schemas only.
RULE 5: Both worker/ and frontend/ import from shared/ — never cross-import.
```

---

## Five Scheduled Cron Jobs

All defined in `worker/src/cron/`. Scheduled in `wrangler.toml`.

| File | Schedule (LKT) | What it does |
|---|---|---|
| `expireSheets.ts` | Every minute | Closes attendance sheets past `code_expires_at` |
| `refreshTrafficScore.ts` | 06:00, 12:00, 18:00 | Resets pulse score bands, writes to KV cache |
| `nightlySettlement.ts` | 01:00 | Sweeps merchant wallet balances to their bank accounts |
| `midnightWalletReset.ts` | 00:00 | Resets `daily_spent_cents` on all wallets |
| `vanReclaim.ts` | 02:00 daily | Checks `expected_grad_year`, updates VAN status to quarantined or eligible |

---

## Key Business Rules

**VAN Lifecycle:**
- VANs are assigned JIT — only when a student first taps "Top Up via Bank"
- Quarantine begins 6 months after `expected_grad_year`
- Recycle eligible 18 months after `expected_grad_year`
- Quarantined VANs bounce all incoming deposits back to sender

**Attendance Code (TOTP Engine):**
- 6 digits, strictly numeric.
- Never stored in the database. Calculated dynamically via `calculate_session_pin()` using HMAC-SHA256 hashing of the `session_secret` and the current Unix minute.
- Automatically rotates every 60 seconds.
- Verification allows a 1-minute drift backward to ensure zero friction for students with slow network connections.

**Network classification:**
- Eduroam → `present` status
- Dialog / Mobitel cellular → `pending_network_verification` status
- Unknown → `pending_network_verification` status
- Classification happens at the Worker based on submitted IP

**Excel export:**
- Triggered automatically on sheet close (timer or manual)
- Contains present students only — no absent rows
- Columns: university_index, full_name, submitted_at, network_type, is_flagged, manual_add
- Sorted by university_index ascending

---

## What Is NOT in Scope (v1)

The following features are designed but not being built in v1.
They are documented in `.agent/11-features-roadmap/`.
Do not build these unless explicitly instructed.

- Loyalty and streaks system
- Parent spending reports (WhatsApp/email)
- Merchant reputation scores and star ratings
- Nutritional tracking dashboard
- Group payment splitting for societies
- Inter-campus expansion
- Offline payment queue
- Step-up authentication / velocity limits
- Biometric authentication

---

## Contact and Ownership

**Technical Founder**: Navod Caldera
**Institution**: University of Moratuwa, AI Undergraduate Batch 23
**Project**: UniPay FinTech Startup
**Classification**: CONFIDENTIAL
