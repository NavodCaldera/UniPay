# UniPay — POS Flow & Real-Time Sync (Bank-Grade)

> **AI Instruction**: This file defines the real-time Point of Sale (POS) interface. The Merchant relies entirely on this screen to know if they should hand over the food. The connection MUST be fault-tolerant, handling campus WiFi drops seamlessly without requiring the cashier to refresh the page.

---

## 1. The SSE Architecture (Why not WebSockets?)

For the UniPay POS, we use **Server-Sent Events (SSE)** instead of WebSockets. 
* **Why:** WebSockets are bidirectional and resource-heavy. The POS tablet only needs to *listen* to the Cloudflare Worker; it doesn't need to speak back. SSE operates over standard HTTP/2, is incredibly lightweight, and has built-in browser reconnection mechanisms.
* **The Vulnerability:** Native SSE can sometimes "zombie" (the browser thinks it's connected, but the server dropped it). Therefore, our frontend must implement a **Heartbeat Monitor**.

---

## 2. The Resilient Connection (Next.js / React Hook)

Developer 3 must build a custom hook that manages the SSE connection, listens for the `ping` heartbeats from the Worker, and forces a hard reconnect if the heartbeat goes missing for more than 45 seconds.

```typescript
// src/hooks/useMerchantPulse.ts
import { useState, useEffect, useRef } from 'react';

export type PaymentEvent = {
    id: string;
    type: 'instant_payment' | 'preorder_claim';
    amount_cents: number;
    student_name: string;
    item_name?: string;
};

export function useMerchantPulse(merchantId: string, sessionToken: string) {
    const [latestEvent, setLatestEvent] = useState<PaymentEvent | null>(null);
    const [connectionState, setConnectionState] = useState<'connecting' | 'live' | 'offline'>('connecting');
    
    const eventSourceRef = useRef<EventSource | null>(null);
    const lastHeartbeatRef = useRef<number>(Date.now());

    useEffect(() => {
        let heartbeatInterval: NodeJS.Timeout;

        const connectToPulse = () => {
            setConnectionState('connecting');
            
            // Note: SSE doesn't support Authorization headers natively in the browser API.
            // We pass the secure JWT via a short-lived query parameter OR rely on the HttpOnly cookie.
            eventSourceRef.current = new EventSource(`/api/v1/merchants/live-stream`);

            eventSourceRef.current.onopen = () => {
                setConnectionState('live');
                lastHeartbeatRef.current = Date.now();
            };

            eventSourceRef.current.onmessage = (event) => {
                const data = JSON.parse(event.data);
                
                if (data.type === 'heartbeat') {
                    lastHeartbeatRef.current = Date.now();
                    return;
                }

                // It's a real financial event!
                setLatestEvent(data);
                triggerAudioCue(data.type);
            };

            eventSourceRef.current.onerror = () => {
                setConnectionState('offline');
                eventSourceRef.current?.close();
                // Custom backoff logic can be added here, but SSE natively retries
            };
        };

        // The "Zombie Connection" Slayer
        const monitorHeartbeat = () => {
            const timeSinceLastBeat = Date.now() - lastHeartbeatRef.current;
            if (timeSinceLastBeat > 45000 && connectionState === 'live') {
                console.warn("Heartbeat lost. Forcing reconnect...");
                eventSourceRef.current?.close();
                connectToPulse();
            }
        };

        connectToPulse();
        heartbeatInterval = setInterval(monitorHeartbeat, 10000);

        return () => {
            clearInterval(heartbeatInterval);
            eventSourceRef.current?.close();
        };
    }, [merchantId]);

    return { latestEvent, connectionState, clearEvent: () => setLatestEvent(null) };
}

