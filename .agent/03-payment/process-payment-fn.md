# UniPay — Process Payment Execution

> **AI Instruction**: This file defines the TypeScript implementation for calling the `process_payment` PostgreSQL stored procedure from the Cloudflare Worker. Do not implement local balance checking; rely entirely on the database procedure. Handle database exceptions gracefully and map them to standard HTTP status codes.

---

## 1. The Bridge (Edge to Vault)

The Cloudflare Worker acts as a lightweight router. Its only job during a payment is to validate the shape of the incoming data, extract the user's ID from their secure session, and pass the baton to the database.

By using the Neon Serverless driver (`@neondatabase/serverless`), we execute the complex PL/pgSQL function over a single, fast HTTP connection.

---

## 2. Input Validation (Zod Schema)

Before the Worker even talks to the database, it must strictly validate the payload. We use Zod to ensure no malformed data reaches the SQL execution phase.

```typescript
import { z } from 'zod';

// The strictly typed expected body from the SvelteKit/Mobile client
export const PaymentRequestSchema = z.object({
    payee_wallet_id: z.string().uuid("Invalid Payee Wallet ID"),
    amount_cents: z.number().int().positive("Amount must be a positive integer in cents"),
    type: z.enum(['purchase', 'p2p_transfer']),
    metadata: z.record(z.any()).optional(), // Optional cart items or notes
});

// Headers required by the Idempotency middleware
export const PaymentHeadersSchema = z.object({
    'x-idempotency-key': z.string().uuid(),
    'x-payload-hash': z.string().length(64),
});

import { Hono } from 'hono';
import { neon } from '@neondatabase/serverless';

const app = new Hono<{ Bindings: Env }>();

app.post('/transfer', async (c) => {
    // 1. Extract validated data from middleware
    const user = c.get('user'); // Injected by AuthMiddleware
    const body = await c.req.json();
    const headers = c.req.header();
    const clientIp = c.req.header('cf-connecting-ip') || '0.0.0.0';

    // Validate Schema
    const parsedBody = PaymentRequestSchema.parse(body);
    
    // 2. Initialize Neon DB Connection
    const sql = neon(c.env.DATABASE_URL);

    try {
        // 3. Get the Payer's Wallet ID (Since the JWT only gives us the User ID)
        const [payerWallet] = await sql`
            SELECT id FROM wallets WHERE user_id = ${user.id}
        `;
        
        if (!payerWallet) {
            return c.json({ error: 'Wallet not found for active user' }, 404);
        }

        // 4. Call the 'Engine'
        const [result] = await sql`
            SELECT process_payment(
                ${payerWallet.id}::UUID,
                ${parsedBody.payee_wallet_id}::UUID,
                ${parsedBody.amount_cents}::BIGINT,
                ${parsedBody.type}::transaction_type,
                ${headers['x-idempotency-key']}::UUID,
                ${headers['x-payload-hash']},
                ${clientIp}::INET,
                ${parsedBody.metadata ? JSON.stringify(parsedBody.metadata) : null}::JSONB
            ) AS transaction_event_id;
        `;

        // 5. Success! Return the receipt ID to the frontend
        return c.json({ 
            success: true, 
            transaction_event_id: result.transaction_event_id 
        }, 200);

    } catch (error: any) {
        // 6. Delegate to the Error Mapper
        return handlePaymentError(error, c);
    }
});

function handlePaymentError(error: any, c: any) {
    const errorMsg = error.message || '';

    if (errorMsg.includes('UNIPAY_ERR: INSUFFICIENT_FUNDS')) {
        return c.json({ 
            error: 'Insufficient balance', 
            code: 'INSUFFICIENT_FUNDS' 
        }, 400); // 400 Bad Request
    }

    if (errorMsg.includes('UNIPAY_ERR: IDEMPOTENCY_FORGERY')) {
        return c.json({ 
            error: 'Tampering detected. Payload hash mismatch.', 
            code: 'FORGERY_DETECTED' 
        }, 403); // 403 Forbidden
    }

    if (errorMsg.includes('UNIPAY_ERR: SELF_PAYMENT_PROHIBITED')) {
        return c.json({ 
            error: 'You cannot send money to yourself.', 
            code: 'SELF_PAYMENT' 
        }, 400);
    }

    if (errorMsg.includes('UNIPAY_ERR: WALLET_NOT_ACTIVE')) {
        return c.json({ 
            error: 'One of the accounts is suspended or inactive.', 
            code: 'WALLET_INACTIVE' 
        }, 403);
    }

    // Fallback for unexpected DB crashes (e.g., Ledger Imbalance panic)
    console.error('CRITICAL PAYMENT ERROR:', error);
    return c.json({ 
        error: 'An internal processing error occurred.', 
        code: 'INTERNAL_ERROR' 
    }, 500);
}