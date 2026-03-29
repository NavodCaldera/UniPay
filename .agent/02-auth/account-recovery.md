# UniPay — Account Recovery & Support Flow

> **AI Instruction**: This file dictates the UI and backend protocols for users who cannot access their accounts. Because UniPay uses strict Google SSO (`@uom.lk`), the application itself cannot reset passwords. The app must correctly route the user to the appropriate University authority.

---

## 1. The "No Password" Reality

UniPay delegates authentication to the University of Moratuwa's Google Workspace. Therefore, UniPay does not store passwords, nor can it issue Password Reset OTPs. 

Building a custom OTP flow would bypass the University's mandatory 2FA and brute-force protections, violating our core security architecture.

---

## 2. Frontend UX: Handling Login Issues

On the main login screen, instead of a "Forgot Password?" link, the frontend must provide a **"Having trouble logging in?"** button. This opens a bottom sheet or modal with three specific scenarios:

### Scenario A: Forgot Google Password
* **Trigger:** The student cannot log into their `@uom.lk` account at the Google prompt.
* **Action:** Provide a button linking directly to the Google Account Recovery page (`accounts.google.com/signin/recovery`) or the UoM Center for IT Services (CITeS) helpdesk email.
* **Copy:** *"UniPay uses your official university email. If you forgot your password, please reset it through the UoM IT portal."*

### Scenario B: "Unauthorized Domain" Error
* **Trigger:** The student accidentally selects a `@gmail.com` account, and the Worker's "Iron Gate" rejects it with a `403 Forbidden`.
* **Action:** Show a clear error state and a button to "Try Again".
* **Copy:** *"Security Alert: You must use your official @uom.lk email to access UniPay."*

### Scenario C: Account Suspended / Frozen
* **Trigger:** The student logs in successfully via Google, but the Cloudflare Worker checks the database and sees `users.status = 'suspended'`.
* **Action:** The API returns a `403 Account Frozen` error. The frontend must display a dedicated support screen.
* **Copy:** *"Your UniPay account has been temporarily frozen. Please contact the University Finance Office to resolve this issue."*

---

## 3. Backend Implementation (The Support API)

While the app cannot reset passwords, it must allow students who are locked out (Scenario C) to contact support without being authenticated.

We expose a single, heavily rate-limited public endpoint for support tickets:

**API Route:** `POST /api/v1/support/ticket`
**Rate Limit:** 1 request per IP per 10 minutes.

**Payload:**
```json
{
  "university_index": "230000X",
  "contact_email": "personal@gmail.com", 
  "issue_type": "account_frozen",
  "message": "I lost my phone yesterday and requested a freeze. I have a new phone now."
}