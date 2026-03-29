# UniPay — JWT Payload Specification & Security

> **AI Instruction**: This file defines the exact JSON structure and cryptographic signing rules for the Cloudflare Worker's custom session token. Developers must strictly adhere to the "Skinny Token" principle outlined here.

---

## 1. The "Skinny Token" Principle

A JSON Web Token (JWT) is essentially a base64-encoded JSON object. While we encrypt the *signature*, the *payload* itself is readable by anyone who gets their hands on the cookie. 

Therefore, UniPay enforces the **Skinny Token Principle**:
1. **No PII:** Never include the user's Name, Email, Phone Number, or University Index inside the JWT.
2. **No Volatile Data:** Never include the user's wallet balance. Balances change constantly; if it were in the JWT, the token would instantly be out of sync with the true database ledger.
3. **Identifiers Only:** The token should only contain the minimum data required for the `AuthMiddleware` to identify the user and check their permissions.

---

## 2. The JWT Payload Structure (TypeScript Interface)

When generating the token in the `session-exchange` endpoint, the payload must strictly match this interface:

```typescript
export interface UniPayJwtPayload {
    /**
     * Subject: The user's primary UUID from the Neon PostgreSQL `users` table.
     * Note: This is NOT the Firebase UID. We decouple the database from the IdP.
     */
    id: string;

    /**
     * The user's Role-Based Access Control (RBAC) tier.
     * Used by the `RequireRole` middleware to block unauthorized routes instantly.
     */
    role: 'undergraduate' | 'lecturer' | 'merchant' | 'finance_officer' | 'super_admin';

    /**
     * Session ID: A unique UUID for this specific login instance.
     * Crucial for the "Kill Switch" (Revocation) so we can log out a specific device 
     * without logging the user out of all their devices.
     */
    sid: string;

    /**
     * Issued At: Unix timestamp (seconds) when the token was created.
     */
    iat: number;

    /**
     * Expiration: Unix timestamp (seconds) when the token dies.
     * Evaluated dynamically (7 days for students, 4 hours for admins).
     */
    exp: number;
}