# Ambient Display — Deployment & Setup Guide 🚀

> **Self-Hosted & Build-Your-Own Philosophy**  
> Ambient Display is completely open-source and decentralized. **No pre-built binaries (such as `.apk` or `.dmg` files) or hosted cloud backends are distributed.** Every user compiles and runs their own client apps and—if cloud synchronization is desired—provisions their own private Firebase instance.

---

## Table of Contents
1. [Architecture & Modes](#1-architecture--modes)
2. [Mode A: Local-Only (Zero Setup, No Cloud)](#2-mode-a-local-only-zero-setup-no-cloud)
   - [macOS Workstation App](#macos-workstation-app)
   - [Android Companion App](#android-companion-app)
3. [Mode B: Cloud Sync (Self-Hosted Firebase)](#3-mode-b-cloud-sync-self-hosted-firebase)
   - [Step 1: Create Firebase Project](#step-1-create-firebase-project)
   - [Step 2: Enable Google Authentication](#step-2-enable-google-authentication)
   - [Step 3: Enable Cloud Firestore](#step-3-enable-cloud-firestore)
   - [Step 4: Deploy Security Rules](#step-4-deploy-security-rules)
   - [Step 5: Configure Android App](#step-5-configure-android-app)
   - [Step 6: Configure macOS App](#step-6-configure-macos-app)
   - [Step 7: Build, Run & Authenticate](#step-7-build-run--authenticate)
4. [Security & Credentials Hygiene](#4-security--credentials-hygiene)
5. [Troubleshooting & FAQs](#5-troubleshooting--faqs)

---

## 1. Architecture & Modes

Ambient Display supports two operating modes:

```
┌─────────────────────────────────────────────────────────────┐
│                 Mode A: Local-Only (LAN)                    │
│  • 100% Peer-to-Peer over local Wi-Fi                       │
│  • Automatic mDNS / Bonjour discovery (:8321)               │
│  • Zero accounts, zero API keys, zero cloud dependencies    │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                 Mode B: Cloud Sync (Firebase)               │
│  • Remote control across different networks & cellular data │
│  • Multi-device fleet discovery & presence tracking         │
│  • Strict Google Sign-In authentication                     │
│  • Completely isolated in your own private Firebase project │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Mode A: Local-Only (Zero Setup, No Cloud)

If your phone and Mac are connected to the same Wi-Fi network, **you do not need Firebase or any cloud configuration**.

### macOS Workstation App
1. Open Terminal and navigate to `macos-app`:
   ```bash
   cd macos-app
   ```
2. Build and run the app:
   ```bash
   swift run AmbientDisplay
   ```
3. A menu bar icon (`🖥️`) will appear. The workstation starts an embedded HTTP server listening on port `8321` and announces itself via Bonjour.

### Android Companion App
1. Open Terminal and navigate to `android-app`:
   ```bash
   cd android-app
   ```
2. Ensure an Android device or emulator is connected via USB (`adb devices`).
3. Build and install:
   ```bash
   gradle assembleDebug
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```
4. Launch **Ambient Display** on your phone.
5. In the app, either:
   - Tap **Discover Local Mac** (uses mDNS Bonjour to auto-detect your workstation), or
   - Manually enter your Mac's local IP address (e.g. `http://192.168.1.50:8321`).
6. Dispatch ambient billboards, sunrise countdowns, and media loops directly!

---

## 3. Mode B: Cloud Sync (Self-Hosted Firebase)

To control workstations remotely, manage multi-machine fleets, and sync presence status across networks, deploy your own Firebase backend using the free Spark (or Blaze) plan.

### Step 1: Create Firebase Project
1. Go to the [Firebase Console](https://console.firebase.google.com/).
2. Click **Add Project** and give it a name (e.g. `my-ambient-display`).
3. Google Analytics can be disabled or enabled based on your preference.
4. Click **Create Project**.

### Step 2: Enable Google Authentication
1. In your Firebase console sidebar, navigate to **Build > Authentication**.
2. Click **Get Started**.
3. Under the **Sign-in method** tab, choose **Google**.
4. Enable the provider, select your project support email, and click **Save**.
5. Under **Authentication > Settings > Authorized domains**, ensure `localhost` is listed (it is by default).

### Step 3: Enable Cloud Firestore
1. In the sidebar, navigate to **Build > Firestore Database**.
2. Click **Create Database**.
3. Choose a database location closest to you and select **Start in production mode**.
4. Click **Create**.

### Step 4: Deploy Security Rules
The repository includes production-hardened rules in [`firestore.rules`](../firestore.rules) that restrict all document reads and writes strictly to the authenticated Google account owning the document (`/users/{userId}/*`).

1. Install the Firebase CLI (if not already installed):
   ```bash
   npm install -g firebase-tools
   ```
2. Log in with the Google account that owns your Firebase project:
   ```bash
   firebase login
   ```
3. From the repository root, select your project:
   ```bash
   firebase use --add <your-firebase-project-id>
   ```
4. Deploy the rules:
   ```bash
   firebase deploy --only firestore:rules
   ```

### Step 5: Configure Android App
1. In Firebase Console, click the **Settings (gear icon) > Project settings**.
2. In the **Your apps** section, click **Add app** and select **Android** (`</>`).
3. Set the package name to:
   ```
   com.ambientdisplay
   ```
4. **Important — Add Debug SHA-1 Signing Certificate:**
   To allow Google Sign-In on Android, Firebase requires your debug certificate fingerprint.
   - Run the following in your terminal:
     ```bash
     cd android-app
     gradle signingReport
     ```
   - Look for the `SHA1` fingerprint under `Variant: debug`.
   - Copy the SHA-1 hex string and paste it into the **Debug signing certificate SHA-1** field in Firebase Console.
5. Click **Register app** and download `google-services.json`.
6. Place `google-services.json` into:
   ```
   android-app/app/google-services.json
   ```
   *(Note: This file is ignored by `.gitignore` and will never be committed to git).*

### Step 6: Configure macOS App
You can configure the macOS app either via a configuration file or environment variables:

#### Option A: Via `GoogleService-Info.plist` (Recommended)
1. In Firebase Console under **Project settings > Your apps**, click **Add app** and select **Apple** (iOS).
2. Set the Apple bundle ID to:
   ```
   com.ambientdisplay.mac
   ```
3. Click **Register app** and download `GoogleService-Info.plist`.
4. Place `GoogleService-Info.plist` into:
   ```
   macos-app/GoogleService-Info.plist
   ```
   *(Note: This file is ignored by `.gitignore` and will never be committed to git).*

#### Option B: Via Environment Variables
Alternatively, export the credentials before launching the macOS app:
```bash
export FIREBASE_PROJECT_ID="your-firebase-project-id"
export FIREBASE_API_KEY="your-firebase-api-key"
export FIREBASE_CLIENT_ID="your-client-id.apps.googleusercontent.com"
cd macos-app && swift run AmbientDisplay
```

### Step 7: Build, Run & Authenticate
1. **Launch macOS App:**
   ```bash
   cd macos-app
   swift run AmbientDisplay
   ```
   Click the menu bar icon -> **Preferences** -> **Cloud** tab -> **Sign In with Google**.
   Your browser will open to complete OAuth authentication. Once approved, the workstation registers its presence in Firestore under your account.

2. **Launch Android App:**
   ```bash
   cd android-app
   gradle assembleDebug
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```
   Open the app on your phone, scroll to **Cloud Sync**, and tap **Sign In with Google**.
   Upon signing in with the same Google account, your macOS workstation(s) will automatically appear in the **Workstation Fleet Targets** list with real-time `ONLINE` status pills!

---

## 4. Security & Credentials Hygiene

To protect user security and prevent credential leakage:

1. **Strict `.gitignore` Policy:**
   - `android-app/app/google-services.json`
   - `macos-app/GoogleService-Info.plist`
   - `.env` and `.env.*`
   These are explicitly ignored and must **never** be committed.
2. **Template Example Files:**
   Reference templates are provided with dummy placeholders:
   - `android-app/app/google-services.json.example`
   - `macos-app/GoogleService-Info.plist.example`
3. **Database Isolation:**
   All device documents, active canvases, and commands are strictly scoped to `/users/{userId}/...` in Firestore. No user can read or write data belonging to another user.
4. **Public Repo Safety:**
   No proprietary API keys, service account credentials, or OAuth tokens are bundled into this repository.

---

## 5. Troubleshooting & FAQs

### Q: Android Google Sign-In gives `ApiException: 10` or `DEVELOPER_ERROR`
**Fix:** This almost always means the debug SHA-1 signing fingerprint was not added to your Firebase Android app.
1. Run `gradle signingReport` inside `android-app/`.
2. Copy the `SHA1` key under `debugUnitTest` or `debug`.
3. Go to Firebase Console -> Project Settings -> Your Android app -> Add fingerprint -> Paste the SHA-1.
4. Download the updated `google-services.json` and replace `android-app/app/google-services.json`.
5. Recompile and reinstall: `gradle assembleDebug && adb install -r app/build/outputs/apk/debug/app-debug.apk`.

### Q: macOS app shows "Missing or insufficient permissions"
**Fix:** Make sure you deployed the Firestore security rules:
```bash
firebase deploy --only firestore:rules
```
Also verify that you are signed in with the same Google account on both devices.

### Q: Can I use this app without any Google account or Firebase?
**Yes!** Simply use **Mode A (Local-Only)**. Everything works over your local network without any setup or third-party services.
