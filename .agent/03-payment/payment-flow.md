# UniPay — Payment Sequence & QR Flow

> **AI Instruction**: This file dictates the end-to-end execution flow of a standard payment (both Merchant POS and Student P2P). Frontend and Backend teams must adhere to this exact sequence to ensure synchronization, idempotency, and instant Merchant feedback.

---

## 1. The QR Code Standard (Deep Links)

UniPay relies on standard QR codes that decode into deep links. The frontend mobile app/PWA must be registered to handle the `unipay://` protocol.

There are two types of QR codes the Canteen POS can generate:

* **Static QR (Sticker on the wall):**
  `unipay://pay?payee_id=<MERCHANT_UUID>`
  *Flow:* Student scans -> App prompts student to type in the amount -> Student confirms.
* **Dynamic QR (Generated on a tablet for a specific order):**
  `unipay://pay?payee_id=<MERCHANT_UUID>&amount_cents=65000&order_ref=88A2`
  *Flow:* Student scans -> App instantly shows "Pay 650.00 LKR for Order 88A2" -> Student confirms.

---

## 2. The Transaction Sequence (Step-by-Step)

This is the exact chronological order of a payment from the moment the student clicks "Confirm."

### Phase A: The Client-Side Pre-Flight
1. **Biometric Auth:** The UniPay app prompts the student for FaceID/Fingerprint to unlock the wallet.
2. **Payload Construction:** The app builds the JSON payload (`payee_wallet_id`, `amount_cents`).
3. **Idempotency Locking:** The app generates a `UUIDv7` (Idempotency Key) and a SHA-256 hash of the payload.
4. **Network Request:** The app sends the `POST /api/v1/payments/transfer` request to the Cloudflare Worker.

### Phase B: The Edge & Vault Execution
5. **Gateway Check (Worker):** The Worker validates the Firebase JWT, rate limits, and Zod schema.
6. **Execution (Database):** The Worker calls `process_payment()`. Neon locks the rows, checks the balance, updates the ledger, and commits the transaction.
7. **Response:** The Worker returns `200 OK` with the `transaction_event_id`.

### Phase C: The UI Resolution
8. **Student UI:** The student's app receives the `200 OK`, plays a success chime, and shows a green checkmark.
9. **Merchant POS (The Real-Time Sync):** The Merchant needs to know the payment succeeded without the student showing them their phone screen. 

---

## 3. Real-Time Merchant Sync (Server-Sent Events)

To make the POS system feel "instant" without overwhelming the database with polling requests, the Cloudflare Worker implements **Server-Sent Events (SSE)** for the Merchant Dashboard.

**How it works:**
1. When the canteen opens their POS dashboard, the frontend establishes a persistent, one-way SSE connection to `GET /api/v1/merchants/live-stream`.
2. When the `process_payment` Worker successfully commits a payment to the database, it publishes a tiny message to **Cloudflare Pub/Sub** or a lightweight **KV** key signaling the `payee_wallet_id`.
3. The SSE endpoint listening for that specific Merchant's ID immediately pushes a JSON event down the open pipe:

```json
{
  "event": "payment_received",
  "data": {
    "transaction_id": "018f3a...",
    "amount_cents": 65000,
    "payer_name": "Navod Caldera",
    "timestamp": "2026-03-29T10:15:30Z"
  }
}