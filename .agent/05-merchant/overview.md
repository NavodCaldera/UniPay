# UniPay — Merchant Point-of-Sale (Overview)

> **AI Instruction**: This directory defines the frontend architecture for the Canteen POS (Point of Sale) system. The UI must support a high-speed, dual-flow environment: accepting instant payments via Static QRs and fulfilling pre-paid meal orders. The interface must be optimized for noisy environments, requiring massive touch targets and instant visual/audio feedback.

---

## 1. The Canteen Operating Model

UniPay canteens do not use complex cash registers or customer-facing screens. The entire operation is managed from a single Android tablet behind the counter, relying on a **Static QR Sticker** placed on the wall for students to scan.

The Merchant app handles two distinct financial flows simultaneously:

1. **Instant Payments (Snacks & Tea):** The student scans the QR, manually types "150 LKR", and pays. The tablet flashes **GREEN**.
2. **Pre-Order Fulfillment (Lunch/Dinner):** The student scans the same QR, the app recognizes they pre-paid for lunch hours ago, and they tap "Claim". The tablet flashes **BLUE**.

---

## 2. UI/UX Hardware Mandates

Canteens during the 12:15 PM lunch rush are chaotic and fast-paced. Developer 3 (Frontend) must adhere to these strict UI rules for the PWA (Progressive Web App):

* **The "Flash" Screen:** A tiny toast notification is useless in a rush. When an SSE (Server-Sent Event) triggers a success state, the *entire background* of the tablet must flash the designated color for 2 seconds, displaying the `Amount/Item` and `Student Name` in massive typography. Cashiers must be able to verify payments using their peripheral vision.
* **Audio Cues:** Every successful event must trigger a loud, distinct sound. Use a high-pitched "Ping" for a claim, and a classic "Cha-Ching" for a new payment.
* **Fat-Finger Friendly:** Buttons (especially for manual overrides or pre-order setup) must be exceptionally large. Cashiers often have greasy or wet hands.
* **Persistent Connection:** The app must aggressively maintain its WiFi connection and automatically reconnect to the SSE stream if the network drops.

---

## 3. Directory Index

With the Pre-Order model locked in, Developers should build the Merchant frontend in this order:

* **`pre-order-dashboard.md`**: The morning setup screen where merchants publish their daily food allocation (e.g., 150 Chicken Rice packets) and monitor the live sales before the time cutoff hits.
* **`pos-flow.md`**: The real-time checkout UI that listens to the Cloudflare Worker's SSE stream to catch incoming payments and pre-order claims instantly.
* **`campus-pulse.md`**: The live analytics view showing the merchant their total daily revenue, transaction count, and queue velocity.
* **`settlement.md`**: The exit strategy UI where the merchant tracks their digital balance and views the status of their nightly T+1 payouts to their real-world bank account.

---

## 4. Role-Based Access

The Merchant App is strictly protected by the `AuthMiddleware`. Only users with the `merchant` role in their JWT can load these screens. Sessions for merchants last for **7 Days** to prevent cashiers from being unexpectedly logged out during the morning breakfast rush.