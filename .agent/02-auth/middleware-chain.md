# UniPay — API Security Middleware (The Bouncer)

> **AI Instruction**: This file defines the Hono.js middleware functions that protect the Cloudflare Worker API. These functions must run *before* any business logic. They are responsible for extracting the secure cookie, verifying the JWT signature, and enforcing Role-Based Access Control (RBAC).

---

## 1. The Perimeter Defense Philosophy

In a Zero Trust architecture, endpoints like `/api/v1/payments/transfer` should never have to worry about checking if a user is logged in. 

Instead, we use a **Middleware Chain**. This is a layer of code that intercepts every incoming HTTP request. 
1. If the request lacks a valid cookie, the middleware instantly drops it and returns a `401 Unauthorized`. 
2. If the cookie is valid, the middleware opens the JWT, extracts the user's ID and Role, and attaches it to the request context so the downstream payment logic can safely use it.

---

## 2. The Core Authentication Middleware

This is the foundational middleware that must be applied to *all* protected routes (Students, Merchants, and Admins). It reads the `HttpOnly` cookie we generated in the Session Exchange phase.

```typescript
import { getCookie } from 'hono/cookie';
import { verify } from 'hono/jwt';
import { createMiddleware } from 'hono/factory';

// Extends the Hono Context to include our verified user data
export type AuthEnv = {
    Variables: {
        user: {
            id: string;
            role: 'undergraduate' | 'lecturer' | 'merchant' | 'finance_officer' | 'super_admin';
            exp: number;
        }
    }
}

export const AuthMiddleware = createMiddleware<AuthEnv>(async (c, next) => {
    // 1. Extract the secure cookie
    const sessionCookie = getCookie(c, 'unipay_session');

    if (!sessionCookie) {
        return c.json({ error: 'Authentication required. No session found.' }, 401);
    }

    try {
        // 2. Cryptographically verify the JWT using the Worker's secret
        // If the token is expired or tampered with, this will throw an error
        const decodedPayload = await verify(sessionCookie, c.env.JWT_SECRET);

        // 3. Attach the verified user payload to the request context
        c.set('user', decodedPayload as AuthEnv['Variables']['user']);

        // 4. Pass control to the actual API endpoint
        await next();

    } catch (error) {
        console.warn('Invalid or expired session token detected.');
        // We do NOT expose the raw error to the client to prevent information leakage
        return c.json({ error: 'Session expired or invalid. Please log in again.' }, 401);
    }
});

// A factory function that accepts an array of allowed roles
export const RequireRole = (allowedRoles: string[]) => {
    return createMiddleware<AuthEnv>(async (c, next) => {
        // Retrieve the user injected by AuthMiddleware
        const user = c.get('user');

        // Failsafe: If RequireRole is accidentally used without AuthMiddleware
        if (!user) {
            return c.json({ error: 'Server configuration error.' }, 500);
        }

        // Check if the user's role exists in the allowed list
        if (!allowedRoles.includes(user.role)) {
            console.warn(`Access Denied: User ${user.id} (${user.role}) attempted to access restricted route.`);
            return c.json({ error: 'Access denied. Insufficient permissions.' }, 403);
        }

        await next();
    });
};

import { Hono } from 'hono';
import { AuthMiddleware, RequireRole } from './middleware/auth';

const app = new Hono();

// ==========================================
// 1. PUBLIC ROUTES (No Auth Required)
// ==========================================
app.post('/api/v1/auth/session', handleSessionExchange); // The login route itself
app.post('/api/v1/webhooks/bank', handleBankWebhook);    // Uses HMAC, not JWT

// ==========================================
// 2. STANDARD PROTECTED ROUTES (Anyone Logged In)
// ==========================================
// Apply base AuthMiddleware to all routes under /payments
app.use('/api/v1/payments/*', AuthMiddleware);

app.post('/api/v1/payments/transfer', async (c) => {
    const user = c.get('user'); // 100% guaranteed to be secure and verified here
    // ... execute payment ...
});

// ==========================================
// 3. HIGH-SECURITY ADMIN ROUTES (Specific Roles Only)
// ==========================================
// Chain the middlewares: Must be logged in AND must be a specific admin role
app.use('/api/v1/admin/*', AuthMiddleware, RequireRole(['super_admin', 'finance_officer']));

app.post('/api/v1/admin/settlements/force', async (c) => {
    const adminUser = c.get('user');
    // ... execute settlement and log to admin_audit_logs ...
});