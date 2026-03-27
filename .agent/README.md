# UniPay AI Context — README

> This is the entry point for every AI coding session.
> Read this file first, then navigate to the relevant folder.

---

## What This Folder Is

The `.agent/` folder contains the complete architectural memory of UniPay.
Every decision, every rule, every data model, and every flow is documented
here in plain English so that any AI coding assistant — GitHub Copilot,
Claude, Cursor, or others — can understand the system without reading the
entire codebase.

---

## Read This First — Always

Before writing any code, read:

```
.agent/00-system/master-architecture.md
```

This file contains the non-negotiable rules that apply to every task.
It takes under 5 minutes to read and prevents every category of mistake.

---

## Then Read the Folder for Your Task

| Task | Read this folder |
|---|---|
| Writing any SQL — tables, functions, migrations | `01-database/` |
| Auth code — Firebase, JWT, cookies, middleware | `02-auth/` |
| Payment logic — QR flow, wallets, idempotency | `03-payment/` |
| Attendance — sheets, codes, marking, export | `04-attendance/` |
| Merchant dashboard — POS, pulse score, SKUs | `05-merchant/` |
| Analytics — presence, probability, forecasting | `06-analytics/` |
| Admin tools — VAN lifecycle, system dashboard | `07-admin/` |
| Cloudflare Worker — routes, middleware, cron | `08-worker/` |
| SvelteKit — components, routing, state, PWA | `09-frontend/` |
| Deploy, env vars, wrangler config | `10-infrastructure/` |

---

## Folder Map

```
.agent/
├── README.md                     ← you are here
│
├── 00-system/                    # Global rules — read every session
│   ├── master-architecture.md    # System overview and all non-negotiable rules
│   ├── tech-stack.md             # Every library with version and rationale
│   ├── coding-standards.md       # TypeScript, naming, patterns, SQL style
│   ├── security-rules.md         # Cookie spec, JWT, SQL injection, XSS, CORS
│   ├── naming-conventions.md     # File, variable, function, DB naming rules
│   └── folder-structure.md       # Complete monorepo folder tree
│
├── 01-database/                  # PostgreSQL on Neon
│   ├── overview.md
│   ├── enums.md
│   ├── tables.md
│   ├── functions.md
│   ├── views.md
│   ├── migrations.md
│   └── seed.md
│
├── 02-auth/                      # Firebase + UniPay JWT session
│   ├── overview.md
│   ├── firebase-setup.md
│   ├── session-exchange.md
│   ├── jwt-spec.md
│   ├── middleware-chain.md
│   ├── revocation.md
│   └── email-verification.md
│
├── 03-payment/                   # The financial engine
│   ├── overview.md
│   ├── payment-flow.md
│   ├── process-payment-fn.md
│   ├── idempotency.md
│   ├── ledger.md
│   ├── topup-van.md
│   ├── topup-card.md
│   └── settlement.md
│
├── 04-attendance/                # Attendance marking system
│   ├── overview.md
│   ├── schema.md
│   ├── code-generation.md
│   ├── create-sheet-flow.md
│   ├── mark-attendance-flow.md
│   ├── close-sheet-flow.md
│   ├── manual-add.md
│   ├── excel-export.md
│   ├── network-classification.md
│   └── fraud-detection.md
│
├── 05-merchant/                  # Merchant POS and analytics
│   ├── overview.md
│   ├── pos-flow.md
│   ├── sku-management.md
│   ├── campus-pulse.md
│   ├── traffic-score-equation.md
│   ├── demand-forecast.md
│   └── settlement.md
│
├── 06-analytics/                 # Campus intelligence layer
│   ├── overview.md
│   ├── campus-presence.md
│   ├── lunch-probability.md
│   ├── traffic-score-cron.md
│   └── time-matched-pacing.md
│
├── 07-admin/                     # System administration
│   ├── overview.md
│   ├── van-lifecycle.md
│   ├── system-dashboard.md
│   ├── society-wallets.md
│   └── vapt-compliance.md
│
├── 08-worker/                    # Cloudflare Workers API
│   ├── overview.md
│   ├── routing.md
│   ├── middleware.md
│   ├── cron-jobs.md
│   ├── event-bus.md
│   ├── kv-cache.md
│   └── observability.md
│
├── 09-frontend/                  # SvelteKit PWA
│   ├── overview.md
│   ├── auth-flow.md
│   ├── runes-guide.md
│   ├── api-client.md
│   ├── routing.md
│   ├── pwa-manifest.md
│   └── component-guide.md
│
├── 10-infrastructure/            # Deployment and environment
│   ├── overview.md
│   ├── env-vars.md
│   ├── deploy.md
│   ├── wrangler-config.md
│   └── neon-config.md
│
└── 11-features-roadmap/          # Future features — DO NOT BUILD YET
    ├── loyalty-streaks.md
    ├── parent-spending-reports.md
    ├── merchant-reputation.md
    ├── nutrition-tracking.md
    ├── group-splitting.md
    └── inter-campus-expansion.md
```

---

## Quick Reference — The Rules That Matter Most

```
Money        → always BIGINT cents, never DECIMAL or FLOAT
Primary keys → always UUID from gen_random_uuid()
Auth token   → always HttpOnly cookie, never localStorage
API calls    → always lib/api/ wrappers, never raw fetch()
Reactivity   → always Svelte 5 Runes, never Svelte 4 stores
Types        → always import from shared/types/, never redefine
Validation   → always import from shared/validation/, never redefine
Payments     → always call process_payment() DB function, never manual UPDATE
Attendance   → present-only model — absent means no row exists
Errors       → never expose stack traces to the client
```

---

## Project Identity

- **Project**: UniPay — Campus Micro-Economy Platform
- **Technical Founder**: Navod Caldera
- **Institution**: University of Moratuwa, AI Undergraduate Batch 23
- **Classification**: CONFIDENTIAL
- **Status**: Pre-production — architecture phase complete, coding phase beginning
