# UniPay — Session Exchange & Role-Based Lifetimes

> **AI Instruction**: This file dictates how the Cloudflare Worker trades a temporary Firebase ID Token for a highly secure, custom API Session Cookie. It enforces strictly different expiration times based on the user's role to balance UX and security.

---

## 1. The "Session Exchange" Concept

Why don't we just use the Firebase Token for every API request?
1. Firebase tokens expire every 1 hour by default, forcing constant silent refreshes that are flaky on mobile networks.
2. Firebase tokens are often stored in `localStorage` by the frontend SDK, making them vulnerable to Cross-Site Scripting (XSS) attacks.

**The Solution:** The frontend sends the Firebase Token to the Worker *once*. The Worker verifies it, throws it away, and gives the frontend a custom UniPay JWT sealed inside an `HttpOnly` cookie. The browser/mobile app handles this cookie automatically, and hackers cannot read it via JavaScript.

---

## 2. Role-Based Session Expiration (TTL)

To optimize the experience without compromising the University's Master Trust account, the Worker calculates the JWT and Cookie expiration (`Max-Age`) dynamically based on the user's database role:

| Role | Expiration (TTL) | Rationale |
| :--- | :--- | :--- |
| `undergraduate` | **7 Days** | Low friction. Students stay logged in all week. (App relies on local Biometrics before payments). |
| `lecturer` | **7 Days** | Same as students. |
| `merchant` | **7 Days** | Canteens use dedicated POS tablets. Keeps staff logged in through the week to avoid morning-rush login delays. |
| `super_admin` / `finance_officer` | **4 Hours** | Maximum security. Admins must re-authenticate frequently to access the dashboard. |

---

## 3. The API Endpoint Implementation (Hono.js)

**Route:** `POST /api/v1/auth/session`
**Input:** `{ "firebase_id_token": "eyJhbGciOiJSUzI1Ni..." }`

This is the exact sequence the Cloudflare Worker must execute:

```typescript
import { Hono } from 'hono';
import { setCookie } from 'hono/cookie';
import { sign } from 'hono/jwt';
import { neon } from '@neondatabase/serverless';

const app = new Hono<{ Bindings: Env }>();

app.post('/session', async (c) => {
    const { firebase_id_token } = await c.req.json();
    const sql = neon(c.env.DATABASE_URL);

    try {
        // 1. Verify Firebase Token Cryptographically
        const decodedFirebaseToken = await verifyFirebaseToken(firebase_id_token, c.env.FIREBASE_PROJECT_ID);
        
        // 2. The Iron Gate: Enforce @uom.lk
        if (!decodedFirebaseToken.email.endsWith('@uom.lk')) {
            return c.json({ error: "Only @uom.lk emails are allowed." }, 403);
        }

        // 3. Look up the User in the Database
        const [user] = await sql`
            SELECT id, role, status FROM users WHERE firebase_uid = ${decodedFirebaseToken.uid}
        `;

        if (!user) {
            return c.json({ error: "User profile not found. Please register first." }, 404);
        }
        if (user.status !== 'active') {
            return c.json({ error: "Account suspended." }, 403);
        }

        // 4. Calculate Role-Based Expiration
        const now = Math.floor(Date.now() / 1000);
        let expirationSeconds;
        
        if (['undergraduate', 'lecturer', 'merchant'].includes(user.role)) {
            expirationSeconds = 7 * 24 * 60 * 60; // 7 Days
        } else {
            expirationSeconds = 4 * 60 * 60;      // 4 Hours (Admins)
        }

        // 5. Generate Custom UniPay JWT
        const customJwtPayload = {
            id: user.id,
            role: user.role,
            iat: now,
            exp: now + expirationSeconds
        };
        const token = await sign(customJwtPayload, c.env.JWT_SECRET);

        // 6. Set the Secure HttpOnly Cookie
        setCookie(c, 'unipay_session', token, {
            path: '/',
            secure: true,           // HTTPS only
            httpOnly: true,         // Unreadable by XSS / JavaScript
            sameSite: 'Strict',     // Prevents CSRF attacks
            maxAge: expirationSeconds
        });

        // 7. Return success to the frontend (but NOT the token!)
        return c.json({ success: true, role: user.role, expires_in: expirationSeconds }, 200);

    } catch (error) {
        console.error("Session Exchange Failed:", error);
        return c.json({ error: "Invalid authentication token." }, 401);
    }
});