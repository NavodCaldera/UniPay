# UniPay — Authentication System Overview

> **AI Instruction**: Read this file before writing any authentication
> code, any middleware, any JWT logic, or any session-related endpoint.
> Every decision here is final. Firebase is used exactly once — at login.
> After the session exchange, the Worker owns everything. Do not suggest
> Firebase Admin SDK for the Worker runtime — it is incompatible with
> Cloudflare Workers and this decision is non-negotiable.

---

## 1. The Auth Philosophy

UniPay uses Firebase exclusively as an identity provider — the same role
Google plays in "Sign in with Google" buttons across the web. Firebase
verifies who the user is at the moment of login. After that single
verification, UniPay takes over completely. The Worker mints its own JWT,
stores its own session, and verifies its own tokens on every request.
Firebase is never called again after the session is established. This means
a Firebase outage after login has zero impact on the running system — active
users experience no interruption.

---

## 2. The Nine-Step Auth Flow

```
Step 1  User opens UniPay and taps "Sign in with Google" or enters
        email and password on the login screen.

Step 2  Firebase Auth processes the login and returns a Firebase
        ID token to the browser. This token is a short-lived JWT
        signed by Google's private keys.

Step 3  The SvelteKit frontend immediately POSTs the Firebase ID token
        to the Worker: POST /api/v1/auth/session
        The token is in the request body — never in a header or URL.

Step 4  The Worker verifies the Firebase ID token using the jose library
        and Google's JWK Set endpoint. No Firebase Admin SDK.
        Correct JWK URL:
        https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com
        The Worker verifies: signature, audience (Firebase project ID),
        issuer (securetoken.google.com/<project_id>), and expiry.

Step 5  The Worker looks up or creates the user row in the users table
        using the verified email and Google UID. First-time login
        creates the user. Subsequent logins update google_id if needed.

Step 6  The Worker creates a row in user_sessions with a unique jwt_jti
        (UUID v4). Then mints a UniPay JWT signed with JWT_SECRET and
        sets it as a secure HttpOnly cookie on the response.

Step 7  The browser stores the cookie automatically. JavaScript on the
        page cannot read it — it is HttpOnly. The Firebase ID token
        is discarded by the frontend immediately after the POST.
        No token is stored in localStorage, sessionStorage, or any
        JavaScript variable.

Step 8  Every subsequent API call from the browser automatically includes
        the cookie. No manual token management. No Authorization header.
        The auth is invisible to the application code.

Step 9  The Worker verifies its own JWT on every protected request:
        a. Verify JWT signature using JWT_SECRET (0ms — pure crypto)
        b. Check exp claim (0ms — pure comparison)
        c. Check KV revocation set for jwt_jti (1ms — edge cache)
        d. If JWT has < 24h remaining → silently reissue new 7-day JWT
        Firebase is never called in this step.
```

---

## 3. Session Model

UniPay uses the simplest session model that is also maximally secure:

```
Login         → Google OAuth or email/password via Firebase
              → Session cookie set → user is authenticated indefinitely

Payments      → Silent always. No PIN, no step-up, no re-authentication.
              → The cookie is the only auth signal.

Logout        → Explicit user action only.
              → Clears cookie from browser.
              → Sets revoked_at on user_sessions row.
              → Writes jti to KV revocation set.

Lost device   → User logs in on another device.
              → Views active sessions list.
              → Kills the lost device's session by its jti.
              → Same revocation process as logout.

Rolling refresh → If JWT has < 24 hours remaining on any request,
                  the Worker silently issues a new 7-day JWT.
                  The user never notices. They never have to log in again
                  as long as they use the app at least once every 7 days.
```

---

## 4. The Two Auth Providers

### Google OAuth
- User taps "Continue with Google"
- Google handles the entire authentication flow
- Firebase returns an ID token with `email_verified: true` always
- Google has already verified the email — no extra gate needed
- UniPay trusts Google OAuth accounts unconditionally on first login

### Email/Password
- User enters email and password
- Firebase verifies the credentials
- Firebase returns an ID token
- **Critical gate**: UniPay checks `email_verified` before issuing a session
- If `email_verified === false` → return 403, show "Verify your email" screen
- The frontend calls Firebase's `sendEmailVerification()` on demand
- Once verified, the user logs in again and gets a session normally

```typescript
// auth.service.ts — email verification gate
if (
  decodedToken.firebase.sign_in_provider === 'password' &&
  !decodedToken.email_verified
) {
  throw new HTTPException(403, {
    message: 'Please verify your email address before signing in.'
  });
}
// Google OAuth accounts skip this check entirely
```

---

## 5. Why Firebase Admin SDK Is Not Used in the Worker

This is a frequent source of confusion. The answer is definitive:

```
Firebase Admin SDK → Uses Node.js APIs:
  - http module (TCP connections)
  - crypto module (Node-specific)
  - fs module (filesystem)

Cloudflare Workers runtime → Does NOT have:
  - Node.js http (uses fetch API instead)
  - Node.js crypto (uses Web Crypto API instead)
  - Node.js fs (no filesystem)

Result: Firebase Admin SDK CANNOT run in Cloudflare Workers.
        It will throw at runtime — not at build time.
        It will appear to work locally but crash in production.
```

**The correct approach:**

```typescript
// worker/src/modules/auth/auth.service.ts
import { createRemoteJWKSet, jwtVerify } from 'jose';

// ✅ CORRECT JWK Set URL — returns JSON Web Key Set
const JWKS = createRemoteJWKSet(
  new URL(
    'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com'
  )
);

// ❌ WRONG URL — returns x509 PEM certificates, not JWK Set
// 'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@...'
// jose cannot parse PEM certificates — this will throw a key parsing error

export async function verifyFirebaseToken(
  idToken: string,
  projectId: string
) {
  const { payload } = await jwtVerify(idToken, JWKS, {
    audience: projectId,
    issuer:   `https://securetoken.google.com/${projectId}`,
  });
  return payload;
}
```

---

## 6. Security Guarantees

| Threat | Protection |
|---|---|
| XSS steals auth token | HttpOnly cookie — JavaScript cannot read `document.cookie` |
| CSRF forged request | `SameSite=Strict` — cookie never sent on cross-site requests |
| Lost or stolen device | Remote session revocation via `DELETE /api/v1/auth/session/:jti` |
| Brute force login | Firebase rate-limits auth attempts natively |
| Unverified email account | Worker rejects `email_verified: false` with 403 |
| JWT replay after logout | `jti` written to KV revocation set with TTL = remaining lifetime |
| Firebase outage after login | Worker verifies its own JWT — Firebase not called after session exchange |
| Token interception in transit | `Secure` flag — cookie transmitted only over HTTPS/TLS 1.3 |
| Expired JWT still used | `exp` claim checked cryptographically on every request |

---

## 7. Cookie Specification

The UniPay session cookie must always have all five of these attributes.
Removing or weakening any one is a security violation.

```
Set-Cookie: unipay_session=<jwt>
  HttpOnly                    ← JS cannot read it
  Secure                      ← HTTPS only
  SameSite=Strict             ← No cross-site requests
  Path=/                      ← All routes
  Max-Age=604800              ← 7 days (rolling refresh resets this)
```

Full cookie specification: `00-system/security-rules.md`

---

## 8. JWT Lifetime and KV Strategy

```
JWT lifetime:        7 days from issue
Rolling refresh:     If < 24h remaining → silently reissue on next request
KV revocation TTL:   Remaining JWT lifetime at time of revocation
KV key format:       revoked_jti:{jti}
KV read latency:     ~1ms (edge cache)
DB check frequency:  Only on revocation (write) — never on normal requests
```

The KV revocation check is the fast path. The `user_sessions` table
is the audit trail. On every normal request: verify JWT signature + check
KV. The database is only queried when a session is created or revoked.
Never on routine API calls.

---

## 9. File Map — Read This File First, Then Navigate Here

| Task | File to read |
|---|---|
| Configuring Firebase project and environment variables | `02-auth/firebase-setup.md` |
| Implementing `POST /api/v1/auth/session` | `02-auth/session-exchange.md` |
| Writing any JWT signing or verification code | `02-auth/jwt-spec.md` |
| Writing a protected route or middleware | `02-auth/middleware-chain.md` |
| Implementing logout or remote session kill | `02-auth/revocation.md` |
| Handling email/password login edge cases | `02-auth/email-verification.md` |
| Handling lost device or account lockout | `02-auth/account-recovery.md` |

---

## 10. What Is Deliberately Out of Scope

```
✗ SMS / OTP verification — not needed, Firebase handles identity
✗ Magic link login — not in v1
✗ Biometric authentication — removed from scope (see master-architecture.md)
✗ Step-up authentication — removed from scope (payments are always silent)
✗ Velocity limits — removed from scope (session cookie is the only gate)
✗ Multiple Google accounts per user — one Google account per UniPay account
✗ Account merging — a student who signed up with email cannot later
  merge with their Google account in v1
✗ Admin-created accounts — all accounts are self-service via Firebase
```

---

## 11. Environment Variables Required

| Variable | Location | Purpose |
|---|---|---|
| `PUBLIC_FIREBASE_API_KEY` | frontend `.env` | Firebase JS SDK initialisation |
| `PUBLIC_FIREBASE_AUTH_DOMAIN` | frontend `.env` | Firebase JS SDK initialisation |
| `PUBLIC_FIREBASE_PROJECT_ID` | frontend `.env` | Firebase JS SDK initialisation |
| `PUBLIC_FIREBASE_APP_ID` | frontend `.env` | Firebase JS SDK initialisation |
| `FIREBASE_PROJECT_ID` | worker secret | JWT audience and issuer verification |
| `JWT_SECRET` | worker secret | Signing and verifying UniPay JWTs |

Full environment variable documentation: `10-infrastructure/env-vars.md`