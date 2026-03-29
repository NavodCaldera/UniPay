# UniPay — Authentication & Security Architecture (Overview)

> **AI Instruction**: This directory defines the perimeter security for UniPay. It outlines the Identity Provider (Firebase), the Session Exchange mechanism, and the Middleware chain that protects the Cloudflare Worker API. All logic here must strictly adhere to the "@uom.lk Walled Garden" principle.

---

## 1. The Core Philosophy (Identity vs. Authority)

In a financial application, Authentication (Who are you?) and Authorization (What can you do?) must be handled with extreme care. UniPay splits these responsibilities:

* **Identity (Firebase + Google Workspace):** We delegate the hard work of verifying a user's identity to Google. By forcing users to log in with their `@uom.lk` accounts, we inherit the University's Two-Factor Authentication (2FA) and brute-force protections. We do not store or manage passwords.
* **Authority (Cloudflare Worker + Neon DB):** Firebase is *not* trusted to authorize financial transactions. Once Firebase proves *who* the user is, the Cloudflare Worker takes over, checks the database to ensure the user isn't suspended, and issues its own highly secure session token.

---

## 2. The "Trust Handshake" (End-to-End Flow)

When a student opens the UniPay app, the authentication follows a strict sequence:

1. **The Google Prompt:** The SvelteKit frontend triggers Firebase Auth, strictly requesting the `uom.lk` Hosted Domain.
2. **The Firebase Token:** The user successfully logs in. Firebase issues a temporary, cryptographically signed `ID Token`.
3. **The Session Exchange:** The frontend immediately sends this Firebase `ID Token` to our Cloudflare Worker (`POST /api/v1/auth/session`).
4. **The Worker Verification:** The Worker cryptographically verifies the Firebase token, checks that the email ends in `@uom.lk`, and looks up the user's `status` in the Neon PostgreSQL database.
5. **The Custom JWT:** If the user is active and valid, the Worker generates its own lightweight JSON Web Token (JWT) containing the user's `id` and `role`. 
6. **The Secure Cookie:** The Worker sends this custom JWT back to the client inside a strictly configured `HttpOnly`, `Secure`, `SameSite=Strict` cookie.
7. **API Access:** For all subsequent payment or data requests, the browser automatically attaches the secure cookie. The frontend code never touches the token directly.

---

## 3. Directory Index

Developer 1 should implement the security layer in the following order:

1. **`firebase-setup.md`**: How to configure Firebase as an Identity Provider and enforce the `@uom.lk` Walled Garden.
2. **`account-recovery.md`**: Support flows for locked-out users (since we have no password resets).
3. **`session-exchange.md`**: The API route that trades a Firebase Token for a secure Cloudflare Worker session cookie.
4. **`jwt-spec.md`**: The exact payload structure and cryptographic signing rules for our custom Worker JWT.
5. **`middleware-chain.md`**: The Hono.js middleware that intercepts all API requests, verifies the JWT, and enforces Role-Based Access Control (RBAC).
6. **`revocation.md`**: The "Kill Switch" mechanism to instantly log out suspended users or stolen devices.

---

## 4. Security Mandates (Non-Negotiable)

* **No LocalStorage for Tokens:** The SvelteKit frontend MUST NEVER store the Worker JWT in `localStorage` or `sessionStorage`. This prevents Cross-Site Scripting (XSS) attacks from stealing session tokens. Always use `HttpOnly` cookies.
* **Short-Lived JWTs:** The Worker JWT should have a short lifespan (e.g., 1 hour). If a token is somehow compromised, the window of opportunity is incredibly small.
* **CSRF Protection:** Because we use cookies, all state-changing API endpoints (`POST`, `PUT`, `DELETE`) must require a custom header (e.g., `X-Requested-With: XMLHttpRequest`) to prevent Cross-Site Request Forgery.