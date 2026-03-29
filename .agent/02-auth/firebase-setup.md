// src/lib/firebase.ts
import { initializeApp, getApps, getApp } from 'firebase/app';
import { getAuth, GoogleAuthProvider, signInWithPopup } from 'firebase/auth';

// 1. Firebase Configuration
// These environment variables must be set in your Next.js .env.local file
const firebaseConfig = {
    apiKey: process.env.NEXT_PUBLIC_FIREBASE_API_KEY,
    authDomain: process.env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN,
    projectId: process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID,
    storageBucket: process.env.NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET,
    messagingSenderId: process.env.NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID,
    appId: process.env.NEXT_PUBLIC_FIREBASE_APP_ID
};

// 2. Initialize Firebase (Singleton pattern for Next.js)
// This prevents Next.js from initializing Firebase multiple times during hot-reloads
const app = !getApps().length ? initializeApp(firebaseConfig) : getApp();
const auth = getAuth(app);

// 3. Configure the "Walled Garden" Google Provider
const googleProvider = new GoogleAuthProvider();

// Strictly enforce the University domain
googleProvider.setCustomParameters({
    hd: 'uom.lk',
    prompt: 'select_account' // Forces the user to pick their UoM account every time
});

// 4. Export the specific login function for the UI components
export const loginWithUniversityEmail = async () => {
    try {
        const result = await signInWithPopup(auth, googleProvider);
        const user = result.user;

        // Final client-side sanity check before sending to our Cloudflare Worker
        if (!user.email?.endsWith('@uom.lk')) {
            await auth.signOut();
            throw new Error('UNAUTHORIZED_DOMAIN');
        }

        // Return the secure ID token to be exchanged for the UniPay HttpOnly Cookie
        const idToken = await user.getIdToken();
        return { user, idToken };

    } catch (error) {
        console.error("Authentication failed:", error);
        throw error;
    }
};

export { app, auth };