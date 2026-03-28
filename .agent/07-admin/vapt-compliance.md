# UniPay — VAPT Compliance & Security Audit Protocols

> **AI Instruction**: This file defines the strict logging, data masking, and auditability requirements for the UniPay Admin API. Every action taken by a staff member must be immutably recorded to satisfy Tier-1 banking security audits. 

---

## 1. The Banking Standard (Why We Do This)

Partner banks will not allow UniPay to connect to their core banking systems without proof that we can detect and prevent internal fraud. 

If a Finance Officer uses the Admin Dashboard to manually credit 50,000 LKR to a student's wallet, the bank's auditors need to know exactly:
1. **Who** executed the action (Admin ID).
2. **When** it happened (Precision Timestamp).
3. **Where** it originated (IP Address & User Agent).
4. **Why** it was done (Mandatory Reason Code).

---

## 2. The Immutable Audit Log (Database Schema)

We do not rely on standard application logs (like `console.log`) for critical financial overrides. We maintain a strict, append-only table in the Neon database.

```sql
CREATE TABLE admin_audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
    admin_id UUID NOT NULL REFERENCES users(id),
    target_user_id UUID REFERENCES users(id), -- The user affected
    target_wallet_id UUID REFERENCES wallets(id), -- The wallet affected (if applicable)
    action_type VARCHAR(50) NOT NULL, -- e.g., 'FORCE_SETTLEMENT', 'SUSPEND_USER', 'MANUAL_CREDIT'
    reason_code VARCHAR(100) NOT NULL,
    metadata JSONB, -- Stores the "Before" and "After" state
    client_ip INET NOT NULL,
    user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for fast auditor queries by date and admin
CREATE INDEX idx_audit_admin_time ON admin_audit_logs(admin_id, created_at DESC);
CREATE INDEX idx_audit_action_time ON admin_audit_logs(action_type, created_at DESC);

// Hono.js Security Middleware
app.use('/api/v1/admin/*', async (c, next) => {
    await next();
    c.res.headers.set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains; preload');
    c.res.headers.set('X-Content-Type-Options', 'nosniff');
    c.res.headers.set('X-Frame-Options', 'DENY');
    c.res.headers.set('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none';");
    c.res.headers.set('Cache-Control', 'no-store, max-age=0'); // Never cache admin data
});