# UniPay — Session Exchange

> **AI Instruction**: This file documents Steps 3 through 6 of the auth
> flow — the moment a Firebase ID token becomes a UniPay HttpOnly cookie.
> This is the most security-critical endpoint in the system. Every
> validation step documented here is mandatory. Skipping any step creates
> a security vulnerability. The endpoint returns no body on success —
> only a Set-Cookie header and HTTP 200.

---

## 1. What This Endpoint Does

The session exchange is a one-time conversion:

```
Firebase ID token (short-lived, JS-readable, Google-signed)
                    ↓
         POST /api/v1/auth/session
                    ↓
UniPay session JWT (7-day, HttpOnly cookie, Worker-signed)
```

After this exchange:
- The Firebase token is discarded — never stored, never used again
- The UniPay cookie manages all subsequent authentication
- Firebase is not called again until the next login

---

## 2. Endpoint Specification

```
Method:       POST
Path:         /api/v1/auth/session
Auth:         None — this is the public auth endpoint
Rate limit:   10 requests per minute per IP (Cloudflare Native Rate Limiting)
Request body: application/json
Response:     200 OK with Set-Cookie header (no body)
              403 if email not verified (email/password accounts)
              401 if Firebase token is invalid or expired
              429 if rate limit exceeded
              500 if database error
```

### Request Body

```typescript
interface SessionExchangeRequest {
  id_token: string;   // Firebase ID token from the frontend
}
```

### Response Headers (success)

```
HTTP/1.1 200 OK
Set-Cookie: unipay_session=<jwt>; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=604800
Content-Type: application/json

Body: { "success": true, "role": "undergraduate" }
```

The `role` is returned in the body so the frontend can immediately
redirect the user to the correct dashboard without an extra API call.

---

## 3. Complete Implementation

### 3.1 Controller

```typescript
// worker/src/modules/auth/auth.controller.ts
import { Hono }          from 'hono';
import { HTTPException } from 'hono/http-exception';
import { zValidator }    from '@hono/zod-validator';
import { z }             from 'zod';
import { AuthService }   from './auth.service';
import { COOKIE_NAME, COOKIE_MAX_AGE } from '../../utils/constants';

const auth = new Hono<{ Bindings: Env }>();

const sessionExchangeSchema = z.object({
  id_token: z.string().min(1, 'Firebase ID token is required'),
});

auth.post(
  '/session',
  zValidator('json', sessionExchangeSchema),
  async (c) => {
    const { id_token } = c.req.valid('json');
    const ip           = c.req.header('CF-Connecting-IP') ?? 'unknown';
    const deviceLabel  = c.req.header('User-Agent')?.slice(0, 100) ?? 'Unknown device';

    const { jwt, role } = await AuthService.exchangeToken(
      c.env,
      id_token,
      ip,
      deviceLabel
    );

    // Set the HttpOnly cookie — all five attributes are mandatory
    c.header('Set-Cookie', [
      `${COOKIE_NAME}=${jwt}`,
      'HttpOnly',
      'Secure',
      'SameSite=Strict',
      'Path=/',
      `Max-Age=${COOKIE_MAX_AGE}`,
    ].join('; '));

    return c.json({ success: true, role }, 200);
  }
);

export { auth };
```

### 3.2 Service — The Core Business Logic

```typescript
// worker/src/modules/auth/auth.service.ts
import { SignJWT }            from 'jose';
import { HTTPException }      from 'hono/http-exception';
import { verifyFirebaseToken } from './firebase.verifier';
import { AuthRepository }     from './auth.repository';
import { getDB }              from '../../db/client';
import type { UniPayJWT }     from '@unipay/shared/types/user';

export const AuthService = {

  async exchangeToken(
    env:         Env,
    idToken:     string,
    ip:          string,
    deviceLabel: string
  ): Promise<{ jwt: string; role: string }> {

    const db = getDB(env);

    // ── STEP 1: Verify Firebase ID token ────────────────────────
    // Uses jose + Google JWK Set — no Firebase Admin SDK
    let firebasePayload;
    try {
      firebasePayload = await verifyFirebaseToken(
        idToken,
        env.FIREBASE_PROJECT_ID
      );
    } catch {
      throw new HTTPException(401, {
        message: 'Invalid or expired Firebase token'
      });
    }

    // ── STEP 2: Email verification gate ─────────────────────────
    // Google OAuth accounts always have email_verified = true
    // Email/password accounts may not — reject unverified accounts
    if (
      firebasePayload.firebase.sign_in_provider === 'password' &&
      !firebasePayload.email_verified
    ) {
      throw new HTTPException(403, {
        message: 'Please verify your email address before signing in.'
      });
    }

    // ── STEP 3: Upsert user in the database ─────────────────────
    // First login: creates the user row
    // Subsequent logins: returns existing user, updates avatar if changed
    const user = await AuthRepository.upsertUser(db, {
      googleId:  firebasePayload.sub,
      email:     firebasePayload.email!,
      fullName:  firebasePayload.name  ?? firebasePayload.email!.split('@')[0],
      avatarUrl: firebasePayload.picture ?? null,
    });

    // ── STEP 4: Check account status ────────────────────────────
    if (user.status === 'suspended') {
      throw new HTTPException(403, {
        message: 'Your account has been suspended. Contact support.'
      });
    }

    // ── STEP 5: Create session record ───────────────────────────
    const jti = crypto.randomUUID();
    await AuthRepository.createSession(db, {
      userId:      user.id,
      jwtJti:      jti,
      deviceLabel: deviceLabel,
    });

    // ── STEP 6: Mint UniPay JWT ──────────────────────────────────
    const jwt = await new SignJWT({
      sub:       user.id,
      role:      user.role,
      has_index: user.university_index !== null,
    } satisfies Omit<UniPayJWT, 'jti' | 'iat' | 'exp'>)
      .setProtectedHeader({ alg: 'HS256' })
      .setJti(jti)
      .setIssuedAt()
      .setExpirationTime('7d')
      .sign(new TextEncoder().encode(env.JWT_SECRET));

    return { jwt, role: user.role };
  },

};
```

### 3.3 Firebase Token Verifier

```typescript
// worker/src/modules/auth/firebase.verifier.ts
import { createRemoteJWKSet, jwtVerify } from 'jose';
import type { FirebaseTokenPayload }      from './auth.types';

// JWK Set is created once and cached by jose automatically
// Google rotates Firebase signing keys periodically —
// createRemoteJWKSet handles key rotation transparently
const FIREBASE_JWKS = createRemoteJWKSet(
  new URL(
    'https://www.googleapis.com/service_accounts/v1/jwk/' +
    'securetoken@system.gserviceaccount.com'
  )
);

export async function verifyFirebaseToken(
  idToken:   string,
  projectId: string
): Promise<FirebaseTokenPayload> {
  const { payload } = await jwtVerify(idToken, FIREBASE_JWKS, {
    audience: projectId,
    issuer:   `https://securetoken.google.com/${projectId}`,
  });
  return payload as FirebaseTokenPayload;
}
```

### 3.4 Repository — Database Operations

```typescript
// worker/src/modules/auth/auth.repository.ts
import type { NeonClient } from '../../db/client';

export const AuthRepository = {

  async upsertUser(
    db: NeonClient,
    params: {
      googleId:  string;
      email:     string;
      fullName:  string;
      avatarUrl: string | null;
    }
  ) {
    // ON CONFLICT: update avatar and name in case they changed in Google
    // Never update email — email is the stable identity anchor
    // Never update role — role is set by admin, not by Google profile
    const result = await db.query<{
      id:               string;
      role:             string;
      status:           string;
      university_index: string | null;
    }>(
      `INSERT INTO users (google_id, email, full_name, avatar_url, role)
       VALUES ($1, $2, $3, $4, 'undergraduate')
       ON CONFLICT (google_id) DO UPDATE SET
         full_name  = EXCLUDED.full_name,
         avatar_url = EXCLUDED.avatar_url,
         updated_at = NOW()
       RETURNING id, role, status, university_index`,
      [params.googleId, params.email, params.fullName, params.avatarUrl]
    );

    if (!result.rows[0]) {
      throw new Error('User upsert returned no rows');
    }

    return result.rows[0];
  },

  async createSession(
    db: NeonClient,
    params: {
      userId:      string;
      jwtJti:      string;
      deviceLabel: string;
    }
  ) {
    await db.query(
      `INSERT INTO user_sessions (user_id, jwt_jti, device_label)
       VALUES ($1, $2, $3)`,
      [params.userId, params.jwtJti, params.deviceLabel]
    );
  },

};
```

---

## 4. First Login vs Returning User

The `upsertUser` function handles both cases atomically:

```
First login (no existing row with this google_id):
  → INSERT new row with role = 'undergraduate' by default
  → Admin must manually change role to 'lecturer', 'merchant', or 'admin'
    after account creation if needed
  → Returns the new user row

Returning login (existing row found):
  → ON CONFLICT (google_id) → UPDATE full_name and avatar_url
  → Role and email are never updated by login
  → Returns the existing user row with current role and status
```

**Default role is `undergraduate`** for all new accounts. Role changes
are an admin operation performed through the admin dashboard after
the user has created their account. There is no role selection on
the sign-up screen.

---

## 5. Frontend Implementation

```typescript
// frontend/src/lib/api/auth.ts
import { signInWithPopup, GoogleAuthProvider,
         signInWithEmailAndPassword }   from 'firebase/auth';
import { auth }                         from '$lib/firebase';
import { client }                       from './client';
import type { UserRole }                from '$shared/types/user';

export interface SessionResult {
  role: UserRole;
}

// Exchange the Firebase ID token for a UniPay session cookie
async function exchangeToken(idToken: string): Promise<SessionResult> {
  const response = await client.post<SessionResult>(
    '/api/v1/auth/session',
    { id_token: idToken }
  );
  return response;
}

// Google OAuth login
export async function loginWithGoogle(): Promise<SessionResult> {
  const provider = new GoogleAuthProvider();
  const credential = await signInWithPopup(auth, provider);
  const idToken = await credential.user.getIdToken();
  return exchangeToken(idToken);
}

// Email/password login
export async function loginWithEmailPassword(
  email:    string,
  password: string
): Promise<SessionResult> {
  const credential = await signInWithEmailAndPassword(auth, email, password);
  const idToken    = await credential.user.getIdToken();
  return exchangeToken(idToken);
}
```

```typescript
// frontend/src/lib/api/client.ts — base client used above
export const client = {
  async post<T>(path: string, body: unknown): Promise<T> {
    const res = await fetch(`${PUBLIC_WORKER_URL}${path}`, {
      method:      'POST',
      credentials: 'include',   // Sends and receives cookies
      headers:     { 'Content-Type': 'application/json' },
      body:        JSON.stringify(body),
    });

    if (!res.ok) {
      const error = await res.json().catch(() => ({ message: 'Unknown error' }));
      throw new APIError(res.status, error.message);
    }

    return res.json();
  },
};

export class APIError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = 'APIError';
  }
}
```

---

## 6. Frontend Auth State (Svelte 5 Runes)

```typescript
// frontend/src/lib/state/auth.svelte.ts
import { loginWithGoogle, loginWithEmailPassword } from '$lib/api/auth';
import type { UserRole } from '$shared/types/user';

let role    = $state<UserRole | null>(null);
let loading = $state(false);
let error   = $state<string | null>(null);

export const authState = {
  get role()    { return role;    },
  get loading() { return loading; },
  get error()   { return error;   },
  get isAuthenticated() { return role !== null; },

  async signInWithGoogle() {
    loading = true;
    error   = null;
    try {
      const result = await loginWithGoogle();
      role = result.role;
      return result.role;
    } catch (e) {
      error = e instanceof Error ? e.message : 'Sign in failed';
      throw e;
    } finally {
      loading = false;
    }
  },

  async signInWithEmail(email: string, password: string) {
    loading = true;
    error   = null;
    try {
      const result = await loginWithEmailPassword(email, password);
      role = result.role;
      return result.role;
    } catch (e) {
      error = e instanceof Error ? e.message : 'Sign in failed';
      throw e;
    } finally {
      loading = false;
    }
  },
};
```

---

## 7. Role-Based Redirect After Login

The `role` returned in the session exchange response determines
where the user is sent immediately after login:

```typescript
// frontend/src/routes/(auth)/login/+page.svelte
<script lang="ts">
  import { authState } from '$lib/state/auth.svelte';
  import { goto }      from '$app/navigation';

  async function handleGoogleLogin() {
    const role = await authState.signInWithGoogle();
    redirectByRole(role);
  }

  function redirectByRole(role: string) {
    const routes: Record<string, string> = {
      undergraduate: '/home',
      lecturer:      '/lecturer/dashboard',
      merchant:      '/pos',
      admin:         '/admin/dashboard',
    };
    goto(routes[role] ?? '/home');
  }
</script>
```

---

## 8. Error Handling Reference

| Scenario | Firebase error | Worker response | Frontend shows |
|---|---|---|---|
| Wrong password | `auth/wrong-password` | — (caught by Firebase) | "Incorrect password" |
| Account not found | `auth/user-not-found` | — (caught by Firebase) | "No account found" |
| Too many attempts | `auth/too-many-requests` | — (caught by Firebase) | "Too many attempts — try later" |
| Email not verified | — | 403 | "Check your inbox and verify your email" |
| Account suspended | — | 403 | "Account suspended — contact support" |
| Invalid Firebase token | — | 401 | "Session expired — please sign in again" |
| Rate limit exceeded | — | 429 | "Too many requests — wait a moment" |
| Database error | — | 500 | "Something went wrong — try again" |

---

## 9. Security Notes

**Why the role is in the response body and not the cookie:**
The role is not sensitive — it determines which dashboard to show, not
what operations are permitted. Permissions are enforced server-side on
every API call. Putting the role in the cookie would require the frontend
to read the cookie to determine routing, which requires removing HttpOnly
— a security regression not worth the marginal convenience.

**Why the Firebase token is not stored:**
The Firebase ID token expires in 1 hour. Storing it would require refresh
logic, a second storage location, and a second verification step on every
request. The UniPay JWT replaces it with a simpler, faster, fully
controlled mechanism.

**Why `ON CONFLICT (google_id)` and not `ON CONFLICT (email)`:**
A user can have the same email on a Google account and as an
email/password account. Conflicting on `google_id` means these are
treated as two separate identities. Conflicting on email would
incorrectly merge them. In v1, account merging is out of scope.

---

## 10. Related Files

- `02-auth/overview.md` — the full nine-step auth flow
- `02-auth/firebase-setup.md` — Firebase project configuration
- `02-auth/jwt-spec.md` — the UniPay JWT payload specification
- `02-auth/middleware-chain.md` — how the cookie is verified on requests
- `02-auth/revocation.md` — the DELETE /api/v1/auth/session endpoint
- `02-auth/email-verification.md` — the 403 flow and resend logic
- `00-system/security-rules.md` — cookie attribute specification