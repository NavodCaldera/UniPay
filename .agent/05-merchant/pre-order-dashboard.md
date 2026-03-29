# UniPay — Pre-Order Dashboard & Fulfillment

> **AI Instruction**: This file defines the frontend UI and operational flow for the Merchant Pre-Order system. It outlines how canteens publish their daily menu, how time-based cutoffs are enforced, and how pre-paid meals are physically claimed during the lunch rush using the standard Static QR code.

---

## 1. The Pre-Order Philosophy (Zero Waste, Zero Wait)

The Pre-Order system separates the **Payment** from the **Fulfillment**. 
1. **The Payment:** The student pays at 10:00 AM while sitting in a lecture. The digital money instantly moves to the Merchant's wallet.
2. **The Fulfillment:** The student walks into the canteen at 12:15 PM, proves they bought the food, and walks out.

Because the money is already secured, the Merchant UI for pre-orders is entirely focused on *Inventory Planning* and *Ticket Redemption*.

---

## 2. Time Windows & Cutoffs

The system operates on strict, rolling time windows. The exact times can be configured later via the Admin Dashboard, but the frontend UI must clearly communicate the current state to both the student and the merchant.

**Standard Windows (Conceptual):**
* **Breakfast:** Pre-orders close at 7:30 AM. Claiming opens at 8:00 AM.
* **Lunch:** Pre-orders close at 11:30 AM. Claiming opens at 12:00 PM.
* **Dinner:** Pre-orders close at 5:30 PM. Claiming opens at 6:30 PM.

*Frontend Rule:* The student mobile app must show a live countdown timer (e.g., *"Order Lunch in the next 45 mins"*). Once the cutoff hits, the frontend must disable the "Buy" button, and the Cloudflare Worker API will reject any late requests.

---

## 3. The Merchant Setup UI (Publishing the Menu)

When the canteen owner opens their tablet in the morning, they need a fast, simple screen to define what they are cooking that day. 

Instead of a complex catalog, they use a **Daily Allocation Screen**:

1.  **Select Category:** The merchant taps "Lunch".
2.  **Add Items & Capacity:** * "Chicken Rice & Curry" -> Limit: 150 packets -> Price: 250 LKR
    * "Veg Rice & Curry" -> Limit: 50 packets -> Price: 200 LKR
3.  **Publish:** The merchant hits "Open for Pre-Orders".

*Live Tracking:* Throughout the morning, this dashboard shows a live progress bar. The canteen owner can look at the tablet at 11:30 AM and see: *"Sold: 142 Chicken, 48 Veg."* They now know exactly how much food to plate.

---

## 4. The Fulfillment Flow (Scanning to Claim)

This is where the UX shines. We do not need a separate QR code for pre-orders. We use the exact same **Static QR Sticker** on the wall.

**The Student Experience:**
1. Navod walks into the canteen at 12:30 PM.
2. He scans the standard Static QR sticker.
3. **The App Intelligence:** The frontend queries the database: *"Does Navod have an active pre-order for this merchant right now?"*
4. Instead of showing the "Enter Amount to Pay" screen, the app immediately shows a digital ticket: **"Tap to Claim: 1x Chicken Rice"**.
5. Navod taps the button.

**The Merchant POS Experience:**
When Navod taps "Claim," the Cloudflare Worker fires a Server-Sent Event (SSE) to the Merchant's tablet. 

To prevent cashiers from getting confused between someone buying a tea right now vs. someone claiming a pre-paid lunch, the UI must use color-coding:
* **Standard Instant Payment:** Tablet flashes **GREEN**. (e.g., "+ 100 LKR for Tea")
* **Pre-Order Claimed:** Tablet flashes **BLUE** or **YELLOW**. (e.g., "CLAIMED: 1x Chicken Rice - Navod C.")

The cashier sees the blue flash, hands over the lunch packet, and the line keeps moving instantly.

---

## 5. Edge Cases & Fallbacks

* **Unclaimed Food:** If a student pre-pays but never shows up to claim their food by the end of the time window, the money remains with the Merchant (since the canteen cooked the food). The ticket expires and drops off the UI.
* **App Offline during Claiming:** If the student's phone loses internet right at the counter, the Merchant UI needs a manual fallback. The POS tablet should have a search bar where the cashier can quickly type the last 4 digits of the student's University Index to manually mark the ticket as "Claimed".