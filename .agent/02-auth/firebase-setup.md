# UniPay — Firebase Setup

> **AI Instruction**: This file covers Firebase project configuration and
> environment variable setup only. It does not cover token verification
> logic (see jwt-spec.md) or the session exchange endpoint (see
> session-exchange.md). When writing frontend Firebase initialisation code
> or Worker token verification code, refer to the specific files for those
> topics. Never use Firebase Admin SDK in the Worker — see overview.md.

---

## 1. Two Firebase Projects — Development and Production

UniPay uses two completely separate Firebase projects:

| Project | Name | Used for |
|---|---|---|
| Development | `unipay-dev` | Local development, staging, testing |
| Production | `unipay-prod` | Live system only |

**Rules:**
- Never use the production Firebase project credentials in any `.env.dev`
  or `.env.staging` file
- Never commit any Firebase credentials to git — all values go in `.env.*`
  files which are gitignored
- The development project can be reset, deleted, or reconfigured freely
- The production project requires admin approval for any configuration change

---

## 2. Creating a Firebase Project

Do this once for development and once for production:

```
1. Go to https://console.firebase.google.com
2. Click "Add project"
3. Name: unipay-dev (or unipay-prod for production)
4. Disable Google Analytics (not needed)
5. Click "Create project"
```

---

## 3. Enabling Authentication Providers

### Step 1 — Open Authentication

```
Firebase Console → Your project → Build → Authentication → Get started
```

### Step 2 — Enable Google OAuth

```
Sign-in providers → Google → Enable → Save

Set authorised domains:
  Development:  localhost
  Production:   unipay.lk (your actual domain)
```

### Step 3 — Enable Email/Password

```
Sign-in providers → Email/Password → Enable

Toggle ON:  Email/Password
Toggle OFF: Email link (passwordless sign-in) — not used in UniPay
Click Save
```

### Step 4 — Authorised Domains

```
Authentication → Settings → Authorised domains

Development project must have:
  localhost
  127.0.0.1

Production project must have:
  unipay.lk
  www.unipay.lk (if applicable)

Remove any default Firebase domains that are not needed.
```

---

## 4. Getting the Frontend Config Values

```
Firebase Console → Project Settings (gear icon) → General tab
→ Scroll to "Your apps" section
→ Click "</>" (Web app) → Register app → name: "UniPay PWA"
→ Copy the firebaseConfig object
```

The config object looks like this:

```javascript
const firebaseConfig = {
  apiKey:            "AIzaSy...",
  authDomain:        "unipay-dev.firebaseapp.com",
  projectId:         "unipay-dev",
  storageBucket:     "unipay-dev.appspot.com",
  messagingSenderId: "123456789",
  appId:             "1:123456789:web:abc123"
};
```

Map these values to frontend environment variables:

| firebaseConfig field | Environment variable |
|---|---|
| `apiKey` | `PUBLIC_FIREBASE_API_KEY` |
| `authDomain` | `PUBLIC_FIREBASE_AUTH_DOMAIN` |
| `projectId` | `PUBLIC_FIREBASE_PROJECT_ID` |
| `appId` | `PUBLIC_FIREBASE_APP_ID` |

`storageBucket` and `messagingSenderId` are not needed — UniPay does not
use Firebase Storage or Firebase Cloud Messaging.

---

## 5. Environment Variable Files

### `infrastructure/env/.env.dev`

```bash
# Firebase — Development project
PUBLIC_FIREBASE_API_KEY=AIzaSy...
PUBLIC_FIREBASE_AUTH_DOMAIN=unipay-dev.firebaseapp.com
PUBLIC_FIREBASE_PROJECT_ID=unipay-dev
PUBLIC_FIREBASE_APP_ID=1:123456789:web:abc123

# Worker needs only the project ID for JWT verification
FIREBASE_PROJECT_ID=unipay-dev

# Worker JWT secret — generate with: openssl rand -base64 32
JWT_SECRET=dev_secret_replace_this_with_real_value

# Neon database
DATABASE_URL=postgres://...@ep-xxx.us-east-1.aws.neon.tech/neondb?sslmode=require

# Frontend URL (for CORS)
FRONTEND_URL=http://localhost:5173

# Worker URL (for frontend API calls)
PUBLIC_WORKER_URL=http://localhost:8787
```

### `infrastructure/env/.env.prod`

```bash
# Firebase — Production project
PUBLIC_FIREBASE_API_KEY=AIzaSy...
PUBLIC_FIREBASE_AUTH_DOMAIN=unipay-prod.firebaseapp.com
PUBLIC_FIREBASE_PROJECT_ID=unipay-prod
PUBLIC_FIREBASE_APP_ID=1:987654321:web:xyz789

# Worker — production values set via Cloudflare secrets (not this file)
# Run: wrangler secret put FIREBASE_PROJECT_ID
# Run: wrangler secret put JWT_SECRET
# Run: wrangler secret put DATABASE_URL
FIREBASE_PROJECT_ID=unipay-prod

# Frontend and Worker URLs
FRONTEND_URL=https://unipay.lk
PUBLIC_WORKER_URL=https://api.unipay.lk
```

**Production secrets** (`JWT_SECRET`, `DATABASE_URL`, `BANK_API_KEY`) are
set via Cloudflare's secret management — never stored in `.env.prod`.
The `.env.prod` file only contains public values that can be in the
frontend bundle.

---

## 6. Frontend Firebase Initialisation

```typescript
// frontend/src/lib/firebase.ts

import { initializeApp, getApps, type FirebaseApp } from 'firebase/app';
import { getAuth, type Auth } from 'firebase/auth';
import {
  PUBLIC_FIREBASE_API_KEY,
  PUBLIC_FIREBASE_AUTH_DOMAIN,
  PUBLIC_FIREBASE_PROJECT_ID,
  PUBLIC_FIREBASE_APP_ID,
} from '$env/static/public';

const firebaseConfig = {
  apiKey:     PUBLIC_FIREBASE_API_KEY,
  authDomain: PUBLIC_FIREBASE_AUTH_DOMAIN,
  projectId:  PUBLIC_FIREBASE_PROJECT_ID,
  appId:      PUBLIC_FIREBASE_APP_ID,
};

// Prevent duplicate initialisation during hot module reload
function getFirebaseApp(): FirebaseApp {
  return getApps().length > 0
    ? getApps()[0]
    : initializeApp(firebaseConfig);
}

export const firebaseApp: FirebaseApp = getFirebaseApp();
export const auth: Auth = getAuth(firebaseApp);
```

**Why `getApps().length > 0` check:**
SvelteKit's hot module reload can re-execute this file during development.
Calling `initializeApp()` twice throws a Firebase error. The check
prevents duplicate initialisation without using a module-level singleton
that persists incorrectly across server-side renders.

---

## 7. Why the Worker Needs Only the Project ID

The Worker does NOT need the Firebase API key, auth domain, or any
other Firebase config value. It only needs `FIREBASE_PROJECT_ID` because:

```
JWT verification requires checking two claims:
  audience (aud):  must equal FIREBASE_PROJECT_ID
  issuer   (iss):  must equal "https://securetoken.google.com/{FIREBASE_PROJECT_ID}"

That is the entire Worker-side Firebase dependency.
No API calls to Firebase at runtime. No SDK. No credentials.
Just one string comparison against the project ID.
```

```typescript
// worker/src/modules/auth/auth.service.ts
import { createRemoteJWKSet, jwtVerify } from 'jose';

const FIREBASE_JWKS = createRemoteJWKSet(
  new URL(
    'https://www.googleapis.com/service_accounts/v1/jwk/' +
    'securetoken@system.gserviceaccount.com'
  )
);

export async function verifyFirebaseToken(
  idToken:   string,
  projectId: string   // = env.FIREBASE_PROJECT_ID
) {
  const { payload } = await jwtVerify(idToken, FIREBASE_JWKS, {
    audience: projectId,
    issuer:   `https://securetoken.google.com/${projectId}`,
  });
  return payload as FirebaseTokenPayload;
}
```

The JWK Set is fetched from Google's endpoint and cached by `jose`
automatically. On subsequent calls, `jose` uses the cached keys unless
they have rotated. Google rotates Firebase signing keys periodically —
`createRemoteJWKSet` handles this transparently.

---

## 8. Firebase Token Payload Shape

After verification, the decoded payload has this shape:

```typescript
// worker/src/modules/auth/auth.types.ts
export interface FirebaseTokenPayload {
  iss:   string;          // "https://securetoken.google.com/unipay-prod"
  aud:   string;          // "unipay-prod"
  sub:   string;          // Firebase UID — unique per user
  email: string;          // User's email address
  email_verified: boolean;// true for Google OAuth, may be false for email/password
  name?: string;          // Display name (Google OAuth only)
  picture?: string;       // Avatar URL (Google OAuth only)
  iat:   number;          // Issued at
  exp:   number;          // Expires at (1 hour from issue)
  firebase: {
    sign_in_provider: 'google.com' | 'password';
    identities: {
      'google.com'?: string[];
      email?:       string[];
    };
  };
}
```

**Key fields used by UniPay:**

| Field | Used for |
|---|---|
| `sub` | Stored as `users.google_id` — unique Firebase UID |
| `email` | Stored as `users.email` — used for first-time user creation |
| `email_verified` | Gate for email/password accounts |
| `name` | Stored as initial `users.full_name` on first login |
| `picture` | Stored as `users.avatar_url` on first login |
| `firebase.sign_in_provider` | Determines whether email verification gate applies |

---

## 9. Testing Firebase Auth Locally

During local development, Firebase Auth works against the real Firebase
development project — there is no local emulator requirement.

**To test Google OAuth locally:**
```
1. Ensure localhost is in the authorised domains list
2. Run the frontend: npm run dev (http://localhost:5173)
3. Click "Continue with Google" — real Google OAuth flow opens
4. Google redirects back to localhost after auth
```

**To test email/password locally:**
```
1. Firebase Console → Authentication → Users → Add user
2. Create a test user with email/password
3. Set email as verified: click the user → Edit → mark email as verified
   (or use the frontend's "send verification email" flow)
```

**Firebase Auth emulator (optional):**
The Firebase Auth emulator can be used for fully offline testing.
This is not required for v1 development but is documented in
`10-infrastructure/` for CI/CD pipeline setup.

---

## 10. Production Security Checklist

Before going live, verify all of these in the production Firebase project:

```
[ ] Production project uses different credentials than development
[ ] Authorised domains contains only unipay.lk (no localhost)
[ ] Email/Password provider is enabled
[ ] Google OAuth provider is enabled with production OAuth client
[ ] App Check is configured (optional but recommended for production)
[ ] Firebase project billing is enabled (Auth is free but needed for quota)
[ ] No Firebase API keys are committed to git
[ ] Production JWT_SECRET is set via: wrangler secret put JWT_SECRET
[ ] JWT_SECRET is minimum 32 bytes: openssl rand -base64 32
```

---

## 11. Related Files

- `02-auth/overview.md` — the full auth flow
- `02-auth/session-exchange.md` — using the verified Firebase token
- `02-auth/jwt-spec.md` — the UniPay JWT that replaces the Firebase token
- `10-infrastructure/env-vars.md` — complete environment variable reference
- `frontend/src/lib/firebase.ts` — the actual initialisation file