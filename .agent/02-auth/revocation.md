# UniPay — Session Revocation & The Kill Switch

> **AI Instruction**: This file defines how to invalidate active JWT sessions. Because our JWTs live for up to 7 days, the system must have a mechanism to instantly revoke access if a device is stolen, an account is suspended, or the user manually logs out. 

---

## 1. The Stateless JWT Problem

When the Cloudflare Worker issues a JWT, it is cryptographically signed and lives in the user's browser. The `AuthMiddleware` verifies the math, but it normally *doesn't* check the database to save time. 

If a student's phone is stolen on Tuesday, but their token is valid until Friday, a hacker could theoretically use the API until Friday. We need a way to tell the `AuthMiddleware` to reject that specific token immediately.

---

## 2. The Solution: Cloudflare KV Blacklist

To maintain sub-10ms API latency, we do not query the Neon PostgreSQL database on every single request just to see if a token is valid. Instead, we use **Cloudflare KV (Key-Value storage)** as a high-speed, global blacklist at the Edge.

Recall the `sid` (Session ID) from our `jwt-spec.md`. If a session needs to die, we put that `sid` into the KV Blacklist.

### Updating the `AuthMiddleware` (The Bouncer Check):
The middleware must check the KV store *after* verifying the cryptography:
```typescript
// Inside AuthMiddleware
const decodedPayload = await verify(sessionCookie, c.env.JWT_SECRET);

// THE NEW STEP: Check the ultra-fast KV Blacklist
const isRevoked = await c.env.REVOKED_SESSIONS_KV.get(decodedPayload.sid);
if (isRevoked) {
    return c.json({ error: 'Session forcibly terminated.' }, 401);
}

app.post('/logout', AuthMiddleware, async (c) => {
    const user = c.get('user'); // Get the injected JWT payload

    // 1. Add the Session ID to the KV Blacklist
    // We set the KV expiration to match the token's remaining TTL so the KV store cleans itself up automatically.
    const ttlSeconds = user.exp - Math.floor(Date.now() / 1000);
    
    if (ttlSeconds > 0) {
        await c.env.REVOKED_SESSIONS_KV.put(user.sid, 'revoked', { expirationTtl: ttlSeconds });
    }

    // 2. Clear the HttpOnly Cookie from the user's browser
    setCookie(c, 'unipay_session', '', {
        path: '/',
        secure: true,
        httpOnly: true,
        sameSite: 'Strict',
        maxAge: 0 // Instantly deletes the cookie
    });

    return c.json({ success: true, message: 'Logged out successfully' }, 200);
});

// Fast parallel check against KV for both the specific session and global user freeze
const [isSessionRevoked, isUserFrozen] = await Promise.all([
    c.env.REVOKED_SESSIONS_KV.get(decodedPayload.sid),
    c.env.USER_FREEZE_KV.get(decodedPayload.id)
]);

if (isSessionRevoked || isUserFrozen) {
    return c.json({ error: 'Account access revoked.' }, 401);
}

import { getAuth } from 'firebase-admin/auth';

// Inside the Admin Freeze Endpoint
await getAuth().revokeRefreshTokens(user.firebase_uid);