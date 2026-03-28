# UniPay — VAN Lifecycle & Automation

> **AI Instruction**: This file details the automated provisioning, freezing, and revocation of Virtual Account Numbers (VANs) for students and staff. The Cloudflare Worker cron jobs must execute these state changes based on the user's `expected_grad_year` and `status`.

---

## 1. The VAN Format Standard

To ensure compatibility with partner banks (like BOC or Sampath) and easy human verification at UoM, Virtual Account Numbers follow a strict deterministic format.

**Format:** `[BANK_PREFIX]-[UNIVERSITY_INDEX]`
**Example for an AI Undergraduate:** `9999-230000X`

* `9999`: The unique identifier for the University's Master Trust Account at the partner bank.
* `230000X`: The student's official university index number.

Because this format is deterministic, the system can generate it automatically upon account creation.

---

## 2. Phase 1: Automated Provisioning (Onboarding)

When a student first registers for the UniPay app using their `@uom.lk` email, the system automatically provisions their digital wallet and assigns their VAN.

**The Workflow (Inside `POST /api/v1/auth/register`):**
1. Student authenticates via Firebase.
2. The Worker extracts the index number from the email or registration form (e.g., `230000X`).
3. The Worker calculates the `expected_grad_year` (e.g., 2023 intake + 4 years = 2027/2028 depending on the program).
4. The Worker inserts the new user into the database, automatically generating the `virtual_account_number`.

```sql
-- The database handles the constraint check to ensure only eligible roles get a VAN
INSERT INTO users (
    firebase_uid, email, role, full_name, university_index, expected_grad_year, virtual_account_number
) VALUES (
    'firebase_abc123',
    'student@uom.lk',
    'undergraduate',
    'Navod Caldera',
    '230000X',
    2028,
    '9999-230000X' 
);

SELECT id, full_name, virtual_account_number 
FROM users 
WHERE role = 'undergraduate' AND expected_grad_year < EXTRACT(YEAR FROM CURRENT_DATE);

UPDATE users 
SET 
    status = 'archived',
    virtual_account_number = NULL -- Frees the constraint, fully detaching the bank bridge
WHERE id = $1 AND expected_grad_year < EXTRACT(YEAR FROM CURRENT_DATE);