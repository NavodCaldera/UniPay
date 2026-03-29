# UniPay — Payment Sequence and QR Flow

> **AI Instruction**: This file defines the exact end-to-end sequence for a
> standard QR payment. Every phase must be implemented in the order shown.
> Do not add authentication steps between scan and payment — the session
> cookie is the only auth. Do not add confirmation screens — the flow is
> scan, preview, confirm, done. The 1.5 second target is non-negotiable.

---

## 1. The QR Code Standard

UniPay uses HTTPS deep links, not custom protocol schemes (`unipay://`).
Custom URL schemes cannot be reliably registered by PWAs on iOS Safari
without a native app wrapper. HTTPS links work on every platform.

### v1 — Static QR Only

Every merchant has one permanent static QR code stored in
`merchants.qr_code_payload`. It encodes a signed HTTPS URL:

```
https://unipay.lk/pay?merchant_id=<MERCHANT_UUID>&sig=<HMAC_SIGNATURE>
```

**`merchant_id`**: The merchant's UUID from the `merchants` table.

**`sig`**: An HMAC-SHA256 signature of `merchant_id` using a server-side
secret. This prevents anyone from manually crafting a fake QR URL pointing
to a different merchant UUID.

**Flow**: Student scans → App fetches merchant name and logo → Student
enters amount → Student confirms → Payment processes.

### v2 — Dynamic QR (Not in v1)

Dynamic QR codes with pre-filled amounts are part of the pre-order feature.
They are documented in `11-features-roadmap/`. Do not implement in v1.

---

## 2. QR Signature Verification

The Worker verifies the QR signature before processing any payment.
This runs inside the payment controller before calling `process_payment()`.

```typescript
// worker/src/modules/payment/payment.service.ts
import { timingSafeEqual } from 'crypto'; // Available in Workers runtime

export async function verifyQRSignature(
  merchantId: string,
  sig: string,
  secret: string
): Promise<boolean> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const expectedBuffer = await crypto.subtle.sign(
    'HMAC',
    key,
    encoder.encode(merchantId)
  );
  const expectedHex = Array.from(new Uint8Array(expectedBuffer))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');

  // Timing-safe comparison prevents timing attacks
  const a = encoder.encode(expectedHex);
  const b = encoder.encode(sig);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}
```

A QR with a mismatched signature returns `403 Forbidden` immediately.
No amount, no merchant name, no data is returned for an invalid QR.

---

## 3. The Complete Payment Sequence

### Phase A — Client Pre-Flight (Frontend)

```
Step 1: Student opens UniPay PWA
Step 2: Student taps "Scan" (home screen shortcut or dashboard button)
Step 3: Camera opens — student scans merchant QR code
Step 4: Frontend parses HTTPS URL, extracts merchant_id and sig
Step 5: Frontend calls GET /api/v1/merchants/:id/preview
        Worker verifies sig, returns { merchant_name, location_label }
Step 6: Frontend displays merchant name and an amount input field
Step 7: Student enters amount and taps "Confirm"
Step 8: Frontend generates idempotency_key = crypto.randomUUID()
        Store this key in component $state — reuse on every retry
Step 9: Frontend builds payload and computes payload_hash (see idempotency.md)
Step 10: Frontend calls POST /api/v1/payments via $lib/api/payment.ts
         Cookie is sent automatically — no manual token handling
```

**Time budget for Phase A**: 0–400ms
(Camera open + QR parse + merchant preview fetch + user input time excluded)

### Phase B — Edge and Database Execution (Worker + Neon)

```
Step 11: Worker receives request at Cloudflare edge (~0ms network to edge)
Step 12: auth.middleware — verify JWT signature + check KV revocation set (~1ms)
Step 13: rateLimit.middleware — Cloudflare Native Rate Limiting (~0ms, network layer)
Step 14: validation.middleware — Zod parse of request body (~0ms)
Step 15: idempotency.middleware — KV edge check (~1ms)
         If 'processing' → return 409
         If 'completed'  → return cached response, done
         Else            → write 'processing' to KV, continue
Step 16: payment.controller — verify QR signature (~1ms)
Step 17: payment.service — call process_payment() on Neon (~10–15ms)
         Inside the DB function (single atomic transaction):
           a. Idempotency guard — check for duplicate key
           b. Forgery check — compare payload_hash
           c. Debit student wallet (balance floor enforced by DB constraint)
           d. Credit merchant wallet
           e. Insert transaction row
           f. Insert two ledger_entries rows (debit + credit)
           g. Return new transaction UUID
Step 18: Worker writes 'completed' + response to KV (~1ms)
Step 19: Worker fires internal event: PaymentCompleted
         Event handler updates campus_presence asynchronously
Step 20: Worker returns 201 Created with transaction_id
```

**Time budget for Phase B**: 15–50ms
(1ms auth + 1ms idempotency + 1ms signature + 15ms DB + 1ms KV write)

### Phase C — UI Resolution (Frontend + Merchant)

```
Step 21: Student app receives 201 response
Step 22: Frontend shows success state:
         - Green checkmark animation
         - "Paid LKR X.XX to [Merchant Name]"
         - Updated balance (fetched fresh or decremented locally)
Step 23: Merchant dashboard receives payment notification
         (see Section 4 — Real-Time Merchant Notification)
```

**Time budget for Phase C**: 0–50ms (render only)

**Total end-to-end target**: under 1,500ms
**Typical actual time**: 200–400ms under normal load

---

## 4. Real-Time Merchant Notification

### Why SSE on Workers Is Problematic

Server-Sent Events require a persistent open connection. Cloudflare Workers
are designed for short-lived request/response cycles. A persistent SSE
connection would keep a Worker CPU instance alive indefinitely, conflicting
with the Workers execution model and creating unbounded CPU cost.

Cloudflare Pub/Sub is currently in beta and not suitable for production.
Durable Objects support WebSockets but add significant architectural
complexity and cost for this use case.

### The Correct Approach for v1 — Smart Polling

Smart polling with an exponential backoff strategy gives the merchant
near-real-time updates (under 3 seconds) at zero infrastructure cost
beyond normal API requests.

```
Merchant dashboard opens
    │
    ▼
Poll GET /api/v1/merchants/payments/latest?after=<last_tx_timestamp>
    │
    ├── Response has new payments → display immediately, reset interval to 2s
    │
    └── Response is empty → increase interval (2s → 4s → 8s → max 30s)
                            Reset to 2s when tab regains focus
```

The Worker caches the latest payment timestamp per merchant in KV.
The polling endpoint reads from KV first (~1ms) and only queries Neon
if KV indicates new activity.

```typescript
// worker/src/modules/merchant/merchant.controller.ts
merchant.get('/payments/latest', authMiddleware, async (c) => {
  const user = c.get('user');
  const after = c.req.query('after'); // ISO timestamp

  // Check KV for latest activity signal first
  const latestSignal = await c.env.KV.get(
    `merchant_activity:${user.sub}`
  );

  // If KV signal is older than the client's last-seen, no new payments
  if (latestSignal && after && latestSignal <= after) {
    return c.json({ payments: [] }, 200);
  }

  // KV signals new activity — fetch from DB
  const payments = await MerchantRepository.getPaymentsSince(
    user.sub,
    after
  );

  return c.json({ payments }, 200);
});
```

**When a payment completes**, the `payment.handler.ts` event handler
writes the current timestamp to `merchant_activity:<merchant_id>` in KV.
The next poll from the merchant hits KV, sees new activity, fetches from
DB, and shows the new payment — all in under 3 seconds.

### Merchant Notification Payload

```typescript
// Returned by GET /api/v1/merchants/payments/latest
interface MerchantPaymentNotification {
  transaction_id:  string;       // UUID
  amount_cents:    number;       // Integer cents
  amount_display:  string;       // "LKR 650.00" — formatted server-side
  payer_name:      string;       // Student's full_name
  transaction_type: 'purchase' | 'preorder';
  completed_at:    string;       // ISO 8601 UTC timestamp
}
```

**The merchant POS shows**: a green flash with amount and payer name.
The flash animates for 3 seconds then becomes a row in the transaction list.

### v2 — Durable Objects WebSocket (Future)

When UniPay expands to multiple campuses and the polling overhead becomes
measurable, upgrade to Cloudflare Durable Objects with WebSocket support.
This is a drop-in replacement for the polling endpoint on the frontend.
Document this migration in `11-features-roadmap/`.

---

## 5. Failure Handling

Every failure state must have a distinct UI response. Silent failures are
not acceptable in a payment system.

| Failure | HTTP Status | Worker action | Student sees | Merchant sees |
|---|---|---|---|---|
| Invalid QR signature | 403 | Reject immediately | "Invalid QR code" | Nothing |
| Insufficient funds | 402 | DB constraint fires | "Insufficient balance — Top up your wallet" | Nothing |
| Duplicate in-flight | 409 | KV hit, processing | "Payment in progress — please wait" | Nothing |
| Idempotency forgery | 422 | DB hash mismatch | "Payment error — contact support" | Nothing |
| Merchant wallet frozen | 403 | DB check fails | "This merchant is unavailable" | Nothing |
| Network timeout | — | No response | "Tap to retry — you have not been charged" | Nothing |
| DB unavailable | 503 | Neon unreachable | "Service unavailable — try again shortly" | Nothing |

**Network timeout handling on the frontend:**

```typescript
// frontend/src/lib/api/payment.ts
export async function processPayment(params: PaymentParams) {
  // idempotencyKey is passed in — generated once in the component
  // and reused on every retry for this payment attempt
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000); // 10s timeout

  try {
    const result = await client.post('/api/v1/payments', payload, {
      signal: controller.signal
    });
    return result;
  } catch (e) {
    if (e instanceof DOMException && e.name === 'AbortError') {
      // Timeout — tell the user they have NOT been charged
      // The same idempotency_key will be used on retry
      throw new Error('PAYMENT_TIMEOUT');
    }
    throw e;
  } finally {
    clearTimeout(timeout);
  }
}
```

---

## 6. The Balance Display Problem

After a successful payment, the student's displayed balance must update
immediately. There are two approaches — use Option B:

**Option A — Re-fetch balance from server (slow, accurate)**
After receiving the 201 response, call `GET /api/v1/users/me/wallet`.
Adds a second round trip. Balance is definitively accurate.

**Option B — Optimistic local decrement (fast, safe)**
After receiving the 201 response, decrement `wallet.svelte.ts` balance
state by `amount_cents` immediately. The next background refresh will
correct any discrepancy. The student sees an instant balance update.

```typescript
// frontend/src/lib/state/wallet.svelte.ts
export function decrementBalance(amountCents: number) {
  // Called immediately after 201 response — no wait for re-fetch
  balanceCents = Math.max(0, balanceCents - amountCents);
}
```

This is safe because the DB has already committed the debit. The local
state will be corrected on the next full wallet fetch. It cannot show a
false positive balance because it only decrements, never invents credits.

---

## 7. Performance Checklist

Before shipping the payment feature, verify every item:

```
[ ] Static QR generation tested for all merchants in seed data
[ ] HMAC signature verification tested with tampered merchant_id
[ ] process_payment() tested with insufficient funds — returns 402
[ ] process_payment() tested with duplicate idempotency_key — returns 201
[ ] process_payment() tested with mismatched payload_hash — returns 422
[ ] Network timeout test — student sees "not charged" message
[ ] Merchant polling tested — new payment appears within 3 seconds
[ ] Balance optimistic decrement tested — shows correct amount after payment
[ ] 409 response tested — duplicate in-flight shows correct message
[ ] p95 latency measured under 100 concurrent payments — must be under 300ms
```

---

## 8. Related Files

- `03-payment/idempotency.md` — full idempotency and anti-forgery protocol
- `03-payment/process-payment-fn.md` — stored function line by line
- `03-payment/ledger.md` — double-entry accounting
- `00-system/security-rules.md` — financial security rules
- `08-worker/routing.md` — all API routes
- `08-worker/event-bus.md` — PaymentCompleted event and handlers