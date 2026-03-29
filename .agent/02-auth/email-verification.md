# UniPay — Domain Verification & Auto-Provisioning

> **AI Instruction**: This file defines the onboarding logic. Because UniPay delegates identity verification to Google SSO, we do not send traditional verification emails. Instead, this logic extracts data from the verified `@uom.lk` email address to automatically provision roles, wallets, and Virtual Account Numbers (VANs) upon first login.

---

## 1. The SSO Advantage (Zero-Friction Onboarding)

In a standard app, registration requires filling out a form, checking your email for a 6-digit OTP, and verifying the address. 

In UniPay, if Firebase successfully issues an ID Token for an `@uom.lk` address, we have mathematical proof that the user is currently an active member of the University. Therefore, the **Registration Flow** and the **Login Flow** are the exact same API endpoint.

---

## 2. The First-Time Login Logic

When the Cloudflare Worker receives the Firebase ID token at `POST /api/v1/auth/session`, it checks the `users` table. If the user does not exist, it triggers the **Auto-Provisioning Protocol**.

### Step 1: Email Pattern Matching
The Worker must analyze the email string to determine the user's role. UoM assigns email addresses based on specific patterns.

```typescript
function parseUniversityEmail(email: string, displayName: string) {
    // Example: navod.c23@uom.lk or 230000X@uom.lk
    // We extract the batch year or index number to auto-assign attributes
    
    let role = 'undergraduate';
    let indexNumber = null;
    let expectedGradYear = null;

    // Regex to catch standard student index patterns (e.g., 230000X)
    const indexMatch = email.match(/^(\d{2})\d{4}[A-Za-z]/);
    
    if (indexMatch) {
        indexNumber = indexMatch[0].toUpperCase();
        const batchYear = parseInt("20" + indexMatch[1]); // "23" -> 2023
        expectedGradYear = batchYear + 4; // Assuming standard 4-year honors degree
    } else {
        // If it doesn't match a student pattern, it's likely a staff member/lecturer
        role = 'lecturer'; 
    }

    return { role, indexNumber, expectedGradYear };
}

// Inside the Worker's Auth Handler (if user does not exist in DB)
const { role, indexNumber, expectedGradYear } = parseUniversityEmail(decodedToken.email, decodedToken.name);

// Generate deterministic VAN if they are a student
const virtualAccountNumber = indexNumber ? `9999-${indexNumber}` : null;

try {
    // Start an atomic transaction
    await sql.begin(async (tx) => {
        // 1. Insert the User
        const [newUser] = await tx`
            INSERT INTO users (
                firebase_uid, 
                email, 
                full_name, 
                role, 
                university_index, 
                expected_grad_year, 
                virtual_account_number,
                status
            ) VALUES (
                ${decodedToken.uid}, 
                ${decodedToken.email}, 
                ${decodedToken.name || 'UoM Member'}, 
                ${role}, 
                ${indexNumber}, 
                ${expectedGradYear}, 
                ${virtualAccountNumber},
                'active'
            ) RETURNING id;
        `;

        // 2. Provision their primary Digital Wallet (starting balance: 0)
        await tx`
            INSERT INTO wallets (
                user_id, 
                type, 
                balance_cents, 
                status
            ) VALUES (
                ${newUser.id}, 
                ${role === 'undergraduate' ? 'student' : 'staff'}, 
                0, 
                'active'
            );
        `;
    });

    console.log(`Auto-provisioned new account for ${decodedToken.email}`);

} catch (error) {
    console.error("Failed to provision new user:", error);
    throw new Error("Database provisioning failed.");
}