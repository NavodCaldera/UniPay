# UniPay — Bank-to-Wallet VAN Top-Up Flow

> **AI Instruction**: This file defines the Webhook listener for Virtual Account Number (VAN) deposits. This is a highly sensitive endpoint. It must enforce strict HMAC signature verification, IP whitelisting, and use the bank's transaction reference as the Idempotency Key.

---

## 1. The Virtual Account Model

Unlike card payments which are pulled from the user, VAN top-ups are **pushed** by the bank. 

The University holds a single "Master Trust Account" at a partner bank (e.g., Bank of Ceylon). The bank assigns "Virtual Account Numbers" (e.g., `9999-230000X`) that route directly into this Master Account. 

When a student transfers 5,000 LKR from their personal banking app to their specific VAN, the partner bank catches it and immediately fires a webhook to the UniPay Edge API.

---

## 2. The Asynchronous Execution Flow

1. **The Deposit:** The student transfers LKR via CEFT/SLIPS to their VAN.
2. **The Webhook:** The partner bank's server makes a `POST` request to `https://api.unipay.lk/v1/webhooks/bank/deposit`.
3. **The Gateway Check (Worker):**
   - Validates the Bank's IP address.
   - Verifies the HMAC cryptographic signature in the headers to ensure the payload wasn't tampered with in transit.
4. **The Resolution:** - The Worker queries the database to find the `user_id` and `wallet_id` associated with the `virtual_account_number` provided in the webhook.
5. **The Ledger Entry:**
   - The Worker executes `process_payment()`.
   - **Payer:** The University "Master Trust" System Wallet.
   - **Payee:** The Student's Wallet.
   - **Idempotency Key:** The Bank's unique Transaction ID.
6. **The Notification:** A push notification is fired to the student: *"Your top-up of 5,000 LKR was successful."*

---

## 3. Webhook Payload & Validation (TypeScript)

The Cloudflare Worker must rigidly parse the incoming payload from the bank.

```typescript
import { z } from 'zod';
import { Hono } from 'hono';
import { neon } from '@neondatabase/serverless';

// The expected schema from the Partner Bank
export const BankWebhookSchema = z.object({
    bank_transaction_id: z.string(), // e.g., "BOC-99283741" (Used as Idempotency Key)
    virtual_account_number: z.string(), // e.g., "9999-230000X"
    amount_cents: z.number().int().positive(),
    currency: z.literal('LKR'),
    timestamp: z.string().datetime()
});

const app = new Hono<{ Bindings: Env }>();

app.post('/webhooks/bank/deposit', async (c) => {
    // 1. Security: HMAC Verification (Crucial)
    const signature = c.req.header('x-bank-signature');
    const rawBody = await c.req.text();
    
    if (!verifyHmac(rawBody, signature, c.env.BANK_WEBHOOK_SECRET)) {
        console.error("WEBHOOK TAMPER ALERT: Invalid Signature");
        return c.json({ error: 'Unauthorized' }, 401);
    }

    const payload = BankWebhookSchema.parse(JSON.parse(rawBody));
    const sql = neon(c.env.DATABASE_URL);

    try {
        // 2. Resolve the VAN to a Student Wallet
        const [studentWallet] = await sql`
            SELECT w.id as wallet_id, u.status 
            FROM wallets w
            JOIN users u ON w.user_id = u.id
            WHERE u.virtual_account_number = ${payload.virtual_account_number}
        `;

        if (!studentWallet || studentWallet.status !== 'active') {
            // TRIGGER ORPHANED FUNDS PROTOCOL
            await logOrphanedFund(payload);
            return c.json({ status: 'flagged_for_manual_review' }, 200); 
            // Note: We return 200 so the bank doesn't retry, but we flag it internally.
        }

        // 3. Process the Top-Up
        // Note: SYSTEM_TRUST_WALLET_ID is an environment variable pointing to the University's main wallet
        await sql`
            SELECT process_payment(
                ${c.env.SYSTEM_TRUST_WALLET_ID}::UUID,
                ${studentWallet.wallet_id}::UUID,
                ${payload.amount_cents}::BIGINT,
                'topup'::transaction_type,
                uuid_generate_v5(uuid_ns_url(), ${payload.bank_transaction_id}) /* Deterministic UUID from Bank Ref */,
                ${await hash(rawBody)},
                '0.0.0.0'::INET,
                ${JSON.stringify({ bank_ref: payload.bank_transaction_id })}::JSONB
            );
        `;

        // 4. Acknowledge Receipt to the Bank
        return c.json({ status: 'success' }, 200);

    } catch (error) {
        console.error('Webhook processing failed:', error);
        return c.json({ error: 'Internal Server Error' }, 500); // Prompts the bank to retry later
    }
});