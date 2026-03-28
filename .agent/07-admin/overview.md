# UniPay — Admin Control Center (Overview)

> **AI Instruction**: This directory defines the Role-Based Access Control (RBAC), monitoring dashboards, and compliance protocols for the University's administrative staff. Admin APIs have the power to move money and suspend users; therefore, they require the highest level of security and auditability.

---

## 1. The Admin Philosophy (Power Requires Proof)

While the Cloudflare Worker operates on "Zero Trust" for students, it must operate on **"Trust but Verify"** for Administrators. 

When an Admin clicks "Force Settlement" or "Suspend Account," the system must execute the action immediately, but it must also permanently record *who* did it, *when*, and *why*. This is mandatory for passing financial audits.

---

## 2. Role-Based Access Control (RBAC)

Not all admins are equal. The `users` table uses the `role` column to define access levels. The Admin API routes must check the Firebase JWT for specific custom claims before executing any function.

| Role | Access Level | Primary Responsibilities |
| :--- | :--- | :--- |
| `super_admin` | **God Mode** | Manages other admins, views deep VAPT compliance logs, and handles critical system overrides. |
| `finance_officer` | **Ledger Only** | Approves `merchant_bank_accounts`, clicks "Force Settlement", and resolves orphaned VAN deposits. Cannot edit user profiles. |
| `support_staff` | **Read & Suspend** | Helps students with lost phones by freezing their `wallet_status`. Views transaction history to resolve disputes. Cannot move money. |

---

## 3. The "Four-Eyes" API Middleware

To protect the Admin routes (`/api/v1/admin/*`), the Cloudflare Worker must implement a stricter middleware chain than the standard student app:

1. **`AdminAuthMiddleware`**: Verifies the Firebase JWT *and* checks that the `role` claim matches the required tier (`super_admin`, `finance`, etc.).
2. **`AuditLoggerMiddleware`**: Every successful `POST`, `PUT`, or `DELETE` request made by an Admin MUST be asynchronously written to an `admin_audit_logs` table (Action, Admin ID, Target ID, Timestamp, IP Address).
3. **`StrictRateLimit`**: Admin endpoints are heavily rate-limited (e.g., 1 request per second) to prevent automated credential-stuffing attacks.

---

## 4. Directory Index

With the core access rules defined, Developers should implement the Admin workflows in this order:

* **`system-dashboard.md`**: The SQL queries and API endpoints to calculate total system liquidity, daily volume, and active user metrics.
* **`van-lifecycle.md`**: The automated/manual rules for provisioning Bank Virtual Account Numbers to new batches and revoking them upon graduation.
* **`vapt-compliance.md`**: The exact logging specifications required to pass a Vulnerability Assessment and Penetration Testing (VAPT) bank audit.