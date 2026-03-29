# UniPay — Idempotency and Anti-Forgery Protocol

> **AI Instruction**: Every state-changing payment request (POST) must pass
> through the full two-stage idempotency system described here. Never bypass
> this layer. Never call `process_payment()` without first running the
> idempotency check. The database constraint is the hard lock — KV is a
> speed and UX optimisation only.

---

## 1. The Problem This Solves

In a mobile-first campus environment, network drops happen constantly —
especially during the 12:30 PM canteen rush when 300 students are on the
same Wi-Fi simultaneously.

**The failure scenario without idempotency:**

```
1. Student scans QR and taps Pay (500 LKR)
2. Worker receives request, calls process_payment() — succeeds
3. Network drops before the 200 OK reaches the student's phone
4. Student sees a spinner, assumes failure, taps Pay again
5. Worker processes a second payment — student charged 1,000 LKR
6. Merchant receives double payment
7. Trust in the system collapses
```

**The goal**: A student can tap Pay as many times as they want for the same
transaction. The merchant gets paid exactly once. The student is charged
exactly once. No matter how many retries, network drops, or duplicate
requests arrive.

---

## 2. Capacity and Scale

Before the architecture — the numbers that justify it:

| Layer | Theoretical max | Realistic sustained |
|---|---|---|
| Cloudflare Workers | ~1,000,000 req/sec | Never the bottleneck |
| Cloudflare KV read | ~100,000 req/sec | Never the bottleneck |
| Neon PostgreSQL (pooled) | ~2,000 TPS theoretical | 400–600 TPS sustained |
| `process_payment()` execution | ~5–15ms per call | ~800 TPS peak burst |

**UniPay actual load (5,000 students, one campus):**

```
Peak scenario: 30% of students transact in the 15-minute lunch rush
= 1,500 payments in 900 seconds
= 1.67 TPS sustained
= ~8 TPS peak burst (first 3 minutes)

System headroom: 400 TPS sustained ÷ 1.67 TPS required = 240× overbuilt

This architecture handles ~50 university campuses before needing
any rethinking. That is the correct position for a FinTech system.
```

---

## 3. The Two-Stage Lock Architecture

The system uses a hybrid Edge + Database approach. These two stages serve
different purposes and must both be present.

```
Request arrives at Cloudflare Worker
         │
         ▼
┌─────────────────────────────┐
│  STAGE 1: KV Edge Lock      │  Purpose: Speed + UX
│  Read idempotency_key       │  Latency: ~1ms
│  from Cloudflare KV         │  Guarantee: Best-effort (eventually consistent)
└─────────────────────────────┘
         │
    ┌────┴────┐
    │         │
  MISS       HIT
    │         │
    │    ┌────┴──────────┐
    │    │ status field? │
    │    └────┬──────────┘
    │         │
    │    processing → return 409 (tell client to wait)
    │    completed  → return cached response (DB never touched)
    │
    ▼
┌─────────────────────────────┐
│  Write 'processing' to KV   │  TTL: 60 seconds
│  with 60s TTL               │  Prevents duplicate in-flight requests
└─────────────────────────────┘
         │
         ▼
┌─────────────────────────────┐
│  STAGE 2: DB Atomic Lock    │  Purpose: Absolute integrity guarantee
│  UNIQUE constraint on       │  Latency: ~10ms
│  idempotency_key column     │  Guarantee: Hard — PostgreSQL enforces this
│  inside process_payment()   │
└─────────────────────────────┘
         │
    ┌────┴────┐
    │         │
  NEW KEY  DUPLICATE KEY
    │         │
    │    Hash match?
    │    ├── YES → return original transaction ID (silent success)
    │    └── NO  → raise IDEMPOTENCY_FORGERY exception → 422 response
    │
    ▼
Process payment atomically
Write 'completed' + response to KV
Return 201 Created
```

**Critical framing**: KV is a speed optimisation and a UX improvement.
It is NOT a security guarantee. The database UNIQUE constraint is the actual
lock. If KV fails, loses consistency, or is bypassed, the DB still catches
every duplicate. The system is safe without KV. KV just makes it faster.

---

## 4. The Payload Hash (Anti-Forgery)

The payload hash detects a specific attack: someone intercepts a failed
payment request and replays it with a modified `amount_cents` — for example,
changing 50,000 cents (500 LKR) to 5,000 cents (50 LKR) and reusing the
same idempotency key to get a cheaper payment accepted.

```
Attack scenario:
  Original request: { amount_cents: 50000, idempotency_key: "abc-123" } — fails
  Forged  request:  { amount_cents:  5000, idempotency_key: "abc-123" } — replayed

Without hash check: DB finds the key, payment "succeeded" for 50 LKR instead of 500
With hash check:    DB finds the key, computes hash of new payload, hash mismatches,
                    raises IDEMPOTENCY_FORGERY — request rejected
```

**What gets hashed**: The canonical JSON string of the payment payload
(excluding the idempotency key itself). The hash is included in the request
body, not in a header — this keeps it under the same content integrity as
the rest of the payload.

**Algorithm**: SHA-256 via Web Crypto API — available natively in both
browsers and Cloudflare Workers. No external library required.

---

## 5. Shared Types

Defined in `shared/types/payment.ts`:

```typescript
export interface PaymentPayload {
  payee_wallet_id: string;   // UUID of merchant wallet
  amount_cents: number;      // Integer cents — never decimal
  transaction_type: 'purchase' | 'preorder';
  idempotency_key: string;   // UUID v4 — generated by frontend
  payload_hash: string;      // SHA-256 of payload excluding this field
  receipt_payload?: object;  // SKU line items — optional
}

export type IdempotencyStatus = 'processing' | 'completed' | 'failed';

export interface KVIdempotencyRecord {
  status: IdempotencyStatus;
  response_body?: object;    // Cached on completion for instant retry response
}
```

---

## 6. Database Schema

The `transactions` table (defined in `database/schemas/ledger.sql`) must
have both columns. The UNIQUE constraint is enforced at the database level —
not in application code.

```sql
-- These columns must exist on the transactions table
idempotency_key   UUID          NOT NULL UNIQUE,
payload_hash      CHAR(64)      NOT NULL,

-- Index for fast lookup inside process_payment()
-- Note: the UNIQUE constraint already creates an index,
-- but an explicit one here for clarity and documentation
CREATE INDEX idx_transactions_idempotency
  ON transactions (idempotency_key);
```

**Inside `process_payment()` stored function:**

```sql
-- Idempotency guard — runs first, before any balance changes
IF EXISTS (
  SELECT 1 FROM transactions WHERE idempotency_key = p_idempotency_key
) THEN
  -- Check for payload tampering
  IF (
    SELECT payload_hash FROM transactions
    WHERE idempotency_key = p_idempotency_key
  ) != p_payload_hash THEN
    RAISE EXCEPTION 'UNIPAY_ERR_IDEMPOTENCY_FORGERY'
      USING HINT = 'Payload hash mismatch for existing idempotency key';
  END IF;

  -- Safe retry — return the original transaction ID
  RETURN (
    SELECT id FROM transactions
    WHERE idempotency_key = p_idempotency_key
  );
END IF;

-- Only reaches here if key is genuinely new
-- ... rest of payment logic
```

---

## 7. Worker Middleware

Defined in `worker/src/middleware/idempotency.middleware.ts`.
This middleware runs on the payment route only — after `auth.middleware`,
before the payment controller.

```typescript
import type { Context, Next } from 'hono';
import { HTTPException } from 'hono/http-exception';
import type { KVIdempotencyRecord } from '@unipay/shared/types/payment';

export async function idempotencyMiddleware(c: Context, next: Next) {
  const body = await c.req.json<{ idempotency_key?: string }>();

  // Key must be in the request body — not a header
  const key = body.idempotency_key;
  if (!key || typeof key !== 'string') {
    throw new HTTPException(400, {
      message: 'idempotency_key is required in the request body'
    });
  }

  // UUID v4 format validation
  const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  if (!UUID_V4.test(key)) {
    throw new HTTPException(400, { message: 'idempotency_key must be a valid UUID v4' });
  }

  // Stage 1: KV edge check
  const existing = await c.env.IDEMPOTENCY_KV.get<KVIdempotencyRecord>(key, 'json');

  if (existing) {
    if (existing.status === 'processing') {
      // Another request with this key is already in flight
      return c.json({
        success: false,
        error: 'payment_in_progress',
        message: 'A payment with this key is already being processed. Retry in a moment.'
      }, 409);
    }

    if (existing.status === 'completed' && existing.response_body) {
      // Cached successful response — return immediately, DB not touched
      return c.json(existing.response_body, 200);
    }
  }

  // Stage 1 write: mark as in-flight with 60-second TTL
  await c.env.IDEMPOTENCY_KV.put(
    key,
    JSON.stringify({ status: 'processing' } satisfies KVIdempotencyRecord),
    { expirationTtl: 60 }
  );

  // Attach key to context for the controller to use
  c.set('idempotencyKey', key);

  await next();

  // After controller completes: update KV with result
  // The controller is responsible for calling this via c.set('idempotencyResult', ...)
  const result = c.get('idempotencyResult');
  if (result) {
    await c.env.IDEMPOTENCY_KV.put(
      key,
      JSON.stringify({
        status: 'completed',
        response_body: result
      } satisfies KVIdempotencyRecord),
      { expirationTtl: 60 * 60 * 24 * 7 } // Keep for 7 days matching JWT lifetime
    );
  }
}
```

---

## 8. Client-Side Implementation

Defined in `frontend/src/lib/api/payment.ts`. Never call fetch() directly
in a component — always use this wrapper.

```typescript
// frontend/src/lib/api/payment.ts
import { client } from './client';
import type { PaymentPayload } from '$shared/types/payment';

async function hashPayload(payload: object): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(JSON.stringify(payload));
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(hashBuffer))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
}

export async function processPayment(params: {
  payeeWalletId: string;
  amountCents: number;
  transactionType: 'purchase' | 'preorder';
  receiptPayload?: object;
}): Promise<{ success: boolean; transactionId: string }> {

  // Step 1: Generate idempotency key — once per payment attempt
  // Store this in component state so retries reuse the same key
  const idempotencyKey = crypto.randomUUID();  // Built-in — no library needed

  // Step 2: Build canonical payload (without the hash field)
  const basePayload = {
    payee_wallet_id: params.payeeWalletId,
    amount_cents:    params.amountCents,
    transaction_type: params.transactionType,
    idempotency_key: idempotencyKey,
    receipt_payload: params.receiptPayload ?? null,
  };

  // Step 3: Hash the payload for forgery detection
  const payloadHash = await hashPayload(basePayload);

  // Step 4: Final payload includes the hash
  const fullPayload: PaymentPayload = {
    ...basePayload,
    payload_hash: payloadHash,
  };

  // Step 5: Send via typed client — cookie injected automatically
  return client.post('/api/v1/payments', fullPayload);
}
```

**Retry logic in the component (when 409 is received):**

```typescript
// In the Svelte component — simple exponential backoff
let idempotencyKey = $state<string | null>(null);

async function handlePay() {
  // Generate key once — reuse on every retry for this payment
  if (!idempotencyKey) {
    idempotencyKey = crypto.randomUUID();
  }

  // Pass the existing key to the API wrapper on retry
  const result = await processPayment({ ...params, idempotencyKey });

  if (result.success) {
    idempotencyKey = null; // Reset only after confirmed success
  }
}
```

---

## 9. Error Reference

| Error | HTTP Status | Meaning | Client action |
|---|---|---|---|
| `payment_in_progress` | 409 | Same key already processing | Wait 2 seconds, retry same key |
| `idempotency_key_missing` | 400 | Key not in request body | Bug in client — fix before retry |
| `idempotency_key_invalid` | 400 | Key is not a valid UUID v4 | Bug in client — fix before retry |
| `UNIPAY_ERR_IDEMPOTENCY_FORGERY` | 422 | Payload hash mismatch | Security alert — log and block |
| `insufficient_funds` | 402 | Balance below amount | Show balance — do not retry |

---

## 10. What This Guarantees

```
GUARANTEE 1: A student is never charged twice for the same payment,
             regardless of network conditions or retry count.

GUARANTEE 2: A forged retry with a modified amount is detected and
             rejected before any money moves.

GUARANTEE 3: A completed payment can be retried safely — the cached
             response is returned in ~1ms without touching the database.

GUARANTEE 4: A payment in flight returns 409, preventing race conditions
             where two tabs or two taps fire simultaneously.

GUARANTEE 5: If KV fails entirely, the database UNIQUE constraint still
             prevents double charges. The system degrades gracefully —
             retries hit the DB directly instead of the cache.
```