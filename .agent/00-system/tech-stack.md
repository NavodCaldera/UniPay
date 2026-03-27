# UniPay — Tech Stack

> **AI Instruction**: This file defines every library and tool in use.
> Do not suggest alternatives. Do not add new dependencies without
> explicit instruction from the developer.

---

## Package Versions (Pinned)

### Frontend (`frontend/package.json`)

```json
{
  "dependencies": {
    "svelte": "^5.0.0",
    "@sveltejs/kit": "^2.0.0",
    "@sveltejs/adapter-cloudflare": "^4.0.0",
    "firebase": "^10.0.0",
    "zod": "^3.22.0"
  },
  "devDependencies": {
    "tailwindcss": "^3.4.0",
    "vite": "^5.0.0",
    "typescript": "^5.3.0",
    "@vite-pwa/sveltekit": "^0.3.0"
  }
}
```

### Worker (`worker/package.json`)

```json
{
  "dependencies": {
    "hono": "^4.0.0",
    "@neondatabase/serverless": "^0.9.0",
    "jose": "^5.0.0",
    "zod": "^3.22.0",
    "exceljs": "^4.4.0"
  },
  "devDependencies": {
    "wrangler": "^3.0.0",
    "typescript": "^5.3.0",
    "@cloudflare/workers-types": "^4.0.0"
  }
}
```

### Shared (`shared/package.json`)

```json
{
  "dependencies": {
    "zod": "^3.22.0"
  },
  "devDependencies": {
    "typescript": "^5.3.0"
  }
}
```

---

## Why Each Tool Was Chosen

### SvelteKit 5 + Runes
Svelte compiles to vanilla JS at build time — no virtual DOM runtime shipped
to the browser. Base bundle ~10KB vs React/Next.js ~45KB. Critical for mobile
users on Sri Lankan 4G networks. Runes are the modern reactivity primitive
replacing Svelte 4 stores. All state files use `.svelte.ts` extension.

### Hono
Purpose-built for Cloudflare Workers. Zero cold start overhead. TypeScript
first. Middleware chaining is clean and predictable. Handles routing,
validation middleware, and error handling without bloat.

### Neon (serverless PostgreSQL)
HTTP-based PostgreSQL driver that works inside Cloudflare Workers (no TCP).
Supports connection pooling. Point-in-time recovery. Branching for staging
environments. The `@neondatabase/serverless` driver is mandatory — standard
`pg` does not work in Workers.

### Firebase Auth
Used exclusively as an identity provider at login time on the frontend. Handles Google OAuth
and email/password with built-in rate limiting and brute-force protection.
**Crucial:** The Worker NEVER uses the `firebase-admin` SDK. The Worker uses `jose` to cryptographically verify the Firebase ID token. After the session exchange, Firebase is not called again — the Worker manages sessions independently.

### Jose (JWT library)
Lightweight, edge-compatible JWT signing and verification. Works in
Cloudflare Workers where Node.js crypto APIs are not available. Used to
mint and verify the UniPay session JWT.

### ExcelJS
Used in `worker/src/modules/attendance/attendance.export.ts` to generate
the attendance Excel file server-side when a sheet closes. Runs inside the
Cloudflare Worker and streams the file buffer to the client.

### shadcn-svelte
Unstyled, accessible component primitives. We own the component code — it
lives in `frontend/src/lib/components/ui/`. No fighting a library's design
opinions for custom payment UI.

### Zod
Schema validation library. Schemas defined once in `shared/validation/` and
imported by both the Worker (API body validation) and the frontend (form
validation). Single source of truth — no schema drift between layers.

---

## What Is Deliberately NOT Used

| Tool | Reason not used |
|---|---|
| React / Next.js | Larger bundle, no native Cloudflare adapter, VDOM overhead |
| Prisma | Does not work in Cloudflare Workers edge runtime |
| Standard `pg` driver | TCP-based, incompatible with Workers |
| Redux / Zustand | Replaced by Svelte 5 Runes |
| JWT in localStorage | Security anti-pattern — XSS readable |
| Firebase Firestore | Not needed — Neon PostgreSQL is the database |
| Firebase for sessions | Only used as identity provider at login |
| next-pwa | Not applicable — SvelteKit uses @vite-pwa/sveltekit |
| Axios | Unnecessary — native fetch with typed wrappers in lib/api/ |
| GraphQL | Overkill for this API surface — REST is sufficient |
| WebSockets | Polling is used for live roster — simpler, cheaper, sufficient |

---

## Cloudflare Services in Use

| Service | Purpose |
|---|---|
| Workers | API runtime (Hono) |
| Pages | Frontend hosting (SvelteKit) |
| KV | Caching pulse scores and session data |
| Cron Triggers | 5 scheduled jobs (see master-architecture.md) |
| Logpush | Structured log forwarding for observability |

---

## Environment Variables

Full list is in `.agent/10-infrastructure/env-vars.md`.

Quick reference for which package needs what:

**Worker needs:**
- `DATABASE_URL` — Neon connection string
- `JWT_SECRET` — for signing UniPay session JWTs
- `FIREBASE_PROJECT_ID` — to verify the audience claim of incoming Firebase ID tokens via jose

**Frontend needs:**
- `PUBLIC_WORKER_URL` — base URL of the Cloudflare Worker API
- `PUBLIC_FIREBASE_API_KEY`
- `PUBLIC_FIREBASE_AUTH_DOMAIN`
- `PUBLIC_FIREBASE_PROJECT_ID`

**Never** put `JWT_SECRET` or Firebase private key in the frontend.
**Never** put `DATABASE_URL` in the frontend.
