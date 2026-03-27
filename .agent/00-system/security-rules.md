# UniPay — Security Rules

> **AI Instruction**: These security rules are non-negotiable. Every line of
> code must comply with them. Never suggest patterns that violate these rules
> even if they are simpler or faster to implement.

---

## Authentication Security

### Cookie Specification
The UniPay session cookie must always be set with all four of these attributes:

```typescript
// In auth.controller.ts — setCookie call
c.header('Set-Cookie', [
  `unipay_session=${jwt}`,
  'HttpOnly',        // JavaScript cannot read this cookie — XSS proof
  'Secure',          // HTTPS only — never sent over HTTP
  'SameSite=Strict', // Never sent on cross-site requests — CSRF proof
  'Path=/',          // Available to all Worker routes
  `Max-Age=${60 * 60 * 24 * 7}` // 7 days
].join('; '));
```

Removing or weakening ANY of these four attributes is a security violation:
- Without `HttpOnly`: XSS attack can steal the token via `document.cookie`
- Without `Secure`: token transmitted in plaintext over HTTP
- Without `SameSite=Strict`: CSRF attacks can forge authenticated requests
- Without `Max-Age`: cookie is session-only — user logs in every browser restart

### Token Storage
```
NEVER store any token in:
  - localStorage
  - sessionStorage
  - window object
  - Svelte state/stores
  - Any JavaScript variable accessible from the page

ALWAYS use HttpOnly cookies exclusively.
```

### JWT Payload
The UniPay JWT must contain exactly these claims:

```typescript
interface UniPayJWT {
  jti: string;          // UUID — unique per session, used for revocation
  sub: string;          // UniPay user UUID from users table
  role: UserRole;       // undergraduate | lecturer | merchant | admin
  has_index: boolean;   // true if university_index is filled — precomputed
  iat: number;          // issued at (Unix timestamp)
  exp: number;          // expires at — 7 days from iat
}
```

Never add sensitive data to the JWT payload (no email, no name, no balance).
The JWT is not encrypted — it is only signed. Anyone can decode it.

### JWT Verification & Revocation (Hybrid Edge Model)
NEVER query the PostgreSQL database to validate a session on every request. Follow this exact flow to maintain ~1ms latency:

1. **Verify Signature & Expiry:** Use `jose` to cryptographically verify the token (0ms).
2. **Check KV Blocklist:** Read `jti` from the Cloudflare KV revocation set (1ms). If present, throw 401.
3. **Rolling Refresh:** If the token has < 24 hours remaining, silently reissue a new 7-day token.

**Revocation Flow (`DELETE /api/v1/auth/session`):**
1. Set `revoked_at = NOW()` in the `user_sessions` DB table (for audit).
2. Write `jti` to the KV revocation set with a TTL equal to the remaining JWT lifetime.
```

---

## Input Validation Security

### All API Inputs Must Be Validated with Zod
No request body, query parameter, or path parameter reaches a controller
without being validated. The validation middleware runs before every controller.

```typescript
// WRONG — unvalidated input
attendance.post('/sheets', authMiddleware, async (c) => {
  const body = await c.req.json();  // RAW — dangerous
  await createSheet(body);
});

// RIGHT — Zod validated before controller runs
attendance.post('/sheets',
  authMiddleware,
  zValidator('json', createSheetSchema),  // validation middleware
  async (c) => {
    const body = c.req.valid('json');  // type-safe, validated
    await createSheet(body);
  }
);
```

### SQL Injection Prevention
Always use parameterised queries. Never use string interpolation in SQL.

```typescript
// WRONG — SQL injection vulnerability
db.query(`SELECT * FROM users WHERE email = '${email}'`);

// RIGHT — parameterised query
db.query('SELECT * FROM users WHERE email = $1', [email]);
```

### XSS Prevention
Svelte's template syntax auto-escapes HTML by default. Never use `{@html}` 
with user-supplied data.

```svelte
<!-- WRONG — XSS if userName contains <script> -->
{@html userName}

<!-- RIGHT — Svelte escapes this automatically -->
{userName}
```

---

## Financial Security

### Atomic Payments
All payment operations go through `process_payment()` PostgreSQL stored
function. The Worker never manually updates wallet balances. This ensures
atomicity — either all four operations succeed or none do.

```typescript
// WRONG — manual balance update, race condition possible
await db.query('UPDATE wallets SET balance_cents = balance_cents - $1 WHERE id = $2', [amount, payerId]);
await db.query('UPDATE wallets SET balance_cents = balance_cents + $1 WHERE id = $2', [amount, payeeId]);

// RIGHT — atomic stored function
await db.query('SELECT process_payment($1, $2, $3, $4, $5, $6, $7)', [
  payerWalletId, payeeWalletId, merchantId,
  amountCents, authMethod, receiptPayload, idempotencyKey
]);
```

### Idempotency
Every payment request must include a client-generated `idempotency_key` (UUID).
The Worker checks this before processing. Duplicate keys return the original
result without charging again.

```typescript
// Frontend generates this before sending
const idempotencyKey = crypto.randomUUID();

// Worker checks before calling process_payment()
const existing = await db.query(
  'SELECT id FROM transactions WHERE idempotency_key = $1',
  [idempotencyKey]
);
if (existing.rows[0]) {
  return c.json({ success: true, transactionId: existing.rows[0].id });
}
```

### Balance Floor
The database enforces `CHECK (balance_cents >= 0)` on `wallets.balance_cents`.
If a payment would cause a negative balance, PostgreSQL throws an error.
The Worker catches this and returns a 402 (insufficient funds) response.
Never check balance in the Worker before the DB call — the DB is the authority.

---

## API Security

### Rate Limiting
All public-facing endpoints are rate-limited via **Cloudflare Native Rate Limiting** configured in `wrangler.toml`. NEVER use Cloudflare KV for rate limiting (it is eventually consistent and easily bypassed).

```toml
# wrangler.toml
[[unsafe.bindings]]
name = "RATE_LIMITER"
type = "ratelimit"
namespace_id = "1001"

POST /api/v1/auth/session    → 10 requests/minute per IP
POST /api/v1/attendance/mark → 5 requests/minute per user
POST /api/v1/payments        → 30 requests/minute per user
```

### Error Responses
Never expose internal details in error responses. The `error.middleware.ts`
intercepts all unhandled errors and returns a sanitised response.

```typescript
// WRONG — exposes internal detail
return c.json({ error: e.message, stack: e.stack }, 500);

// RIGHT — sanitised error
return c.json({ success: false, error: 'Internal server error' }, 500);
```

### CORS
Only the frontend origin is allowed. Set in `worker/src/index.ts`:

```typescript
app.use('*', cors({
  origin: process.env.FRONTEND_URL,  // e.g. https://unipay.lk
  credentials: true,                  // required for cookie-based auth
  allowMethods: ['GET', 'POST', 'PATCH', 'DELETE'],
}));
```

---

## Firebase Security

### Admin SDK Credentials
Firebase Admin SDK private key is a Worker secret — never in source code.

```toml
# wrangler.toml — reference secrets, never hardcode
[vars]
FIREBASE_PROJECT_ID = "unipay-prod"

# Secrets set via: wrangler secret put FIREBASE_PRIVATE_KEY
```
### Token Verification on the Edge

```typescript
// auth.service.ts — runs inside Cloudflare Worker
import { createRemoteJWKSet, jwtVerify } from 'jose';

const JWKS = createRemoteJWKSet(
  new URL(
    'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com'
  )
);

export async function verifyFirebaseToken(idToken: string, projectId: string) {
  const { payload } = await jwtVerify(idToken, JWKS, {
    audience: projectId,
    issuer: `https://securetoken.google.com/${projectId}`,
  });
  return payload;
}
```

### Email Verification Gate
Email/password accounts must have verified their email before getting a session:

// After verifying the Firebase token with jose:
if (
  decodedFirebaseToken.firebase.sign_in_provider === 'password' &&
  !decodedFirebaseToken.email_verified
) {
  throw new HTTPException(403, { message: 'Please verify your email address.' });
}
// Google OAuth accounts automatically pass this, as Google verified the email.

---

## Compliance Notes

### PCI-DSS
UniPay is **out of scope** for PCI-DSS. Card processing is delegated entirely
to PayHere IPG. UniPay never receives, transmits, or stores card numbers.
The Worker only handles the post-payment webhook from PayHere, which contains
a transaction reference — not card data.

### Data Minimisation
Only store data required for system operation:
- No card numbers
- No bank account numbers (except VAN numbers which the bank issues)
- No biometric data
- Passwords are never stored — Firebase handles authentication

### Audit Trail
The `transactions` table is append-only. Never UPDATE or DELETE a transaction.
If a payment must be reversed, insert a new `refund` transaction row.
