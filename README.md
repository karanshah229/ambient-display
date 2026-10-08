# Ambient Display 🖥️✨

> Intelligent Workstation Ambient Canvas & Screen Billboard System for multi-monitor desks and workstation fleets.

**Ambient Display** turns your workstation displays (MacBook, external monitors, or multi-machine fleets) into intelligent ambient surfaces. It combines across-the-room typography billboards, ambient media loops, and circadian sunrise alarms with intelligent phone-to-workstation synchronization—operating both peer-to-peer over local Wi-Fi and globally via Google-authenticated Cloud Sync.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                 Android Companion App                       │
│  • Workstation Fleet Picker (Selective & Broadcast targets) │
│  • Real-Time Presence & Heartbeat Monitoring                │
│  • Multi-Type Ambient Canvas Composer                       │
│  • Inactivity Compensator (dynamic screen timeout credit)   │
│  • Midnight Glance Filter (5-min threshold)                 │
│  • Google Sign-In & Firebase Cloud Sync                     │
└──────────────┬──────────────────────────────┬───────────────┘
               │ Local Wi-Fi (HTTP :8321)     │ Cloud Firestore
               ▼                              ▼
┌─────────────────────────────────────────────────────────────┐
│                 Workstation Fleet Machines                  │
│  • Native macOS Menu Bar Utility (NSStatusItem)             │
│  • Unified Multi-Monitor WindowManager                      │
│  • Zero-OLED-Burn Pure Black Backdrop                       │
│  • Power Assertions (Prevents Display Sleep during active)  │
│  • Supported Renderers:                                     │
│    - High-Visibility Typography Billboard                   │
│    - Circadian Sunrise & Sleep Countdown                    │
│    - Looping Ambient Video (AVPlayerLayer)                  │
│    - Ambient Image Posters                                  │
│    - Webview Dashboards                                     │
└─────────────────────────────────────────────────────────────┘
```

---

## Key Capabilities

### 1. Multi-Device Fleet Targeting (Phase 4)
* **Fleet Discovery:** Discovers and lists all registered workstation machines associated with your Google account.
* **Selective Dispatching:** Send messages and ambient art to specific machines (e.g. `MacBook Air`, `Mac mini`) or broadcast to the entire fleet simultaneously.
* **Live Presence Pills:** Visual `ONLINE` / `OFFLINE` indicators powered by automated heartbeat timestamps (<90s window).
* **Per-Machine Quick Clear:** Dismiss active canvases individually per machine or fleet-wide with a single tap.

### 2. Multi-Type Ambient Canvas (Phase 1 & 2)
* **Typography Billboard:** High-visibility across-the-room messaging with optional subtitle, duration toast, and `phone_only` lock policy.
* **Circadian Sunrise & Sleep Countdown:** Real-time solar calculator and adaptive dawn lighting transitions.
* **Looping Video Surface:** Seamless hardware-accelerated video loops via `AVPlayerLooper`.
* **Image Posters:** Full-screen high-res ambient imagery with dynamic text overlays.
* **Web Dashboards:** Embedded live web surfaces (monitoring boards, dashboards).

### 3. Dual-Tier Connectivity (Local First + Cloud)
* **Instant LAN Peer-to-Peer:** Zero-configuration mDNS / Bonjour discovery with direct REST HTTP fallback on port 8321.
* **Global Cloud Sync (Phase 3):** Powered by Firebase Cloud Firestore, enforcing strict Google OAuth 2.0 authentication security rules.

### 4. Smart Inactivity Compensator & Sleep Watchdog
* Checks `Settings.System.SCREEN_OFF_TIMEOUT` dynamically and calculates exact sleep onset by deducting inactivity gaps.
* Midnight glance filter ignores brief $<5$-minute lockscreen checks.
* macOS kernel power assertions (`PreventUserIdleDisplaySleep`) prevent machine and display sleep while an ambient session is active.

---

## macOS Workstation App Setup

### Prerequisites
* macOS 13.0+
* Xcode Command Line Tools (`swift`)

### Build & Run
```bash
cd macos-app

# 1. Build and test
swift test

# 2. Run app directly
swift run WakeMeUp
```

### Menu Bar Controls
* **Status indicator:** Shows idle, current countdown, or active canvas state.
* **Test Ambient (10s):** Fast-forwards the experience for multi-monitor preview.
* **Cloud Sign-In:** One-click Google Sign-In with browser OAuth.
* **Away Mode:** Suppresses displays when away or traveling.
* **Preferences:** Configure display modes, custom themes, and default sleep durations.

---

## Android App Setup

### Prerequisites
* Android 8.0+ (API 26+)
* Android SDK / Gradle

### Build & Install
```bash
cd android-app
gradle assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

### OnePlus / OxygenOS Immunity Checklist
Built-in setup buttons configure background immunity directly:
1. **Disable Battery Optimization:** Unrestricted background execution.
2. **Grant Usage Access:** Allows calculating inactivity gap when streaming stops.
3. **Enable Watchdog:** Accessibility service prevents process killing.
4. **Auto-Launch Manager:** Enables background secondary launch.

---

## Live End-to-End (E2E) Test Suite

A complete pytest suite verifies all local and cloud workflows:
```bash
.venv/bin/pytest tests/test_live_e2e.py -v
```

Tests include:
* `test_01`–`test_09`: Circadian sleep cycles, display timeouts, power assertions, and glance filters.
* `test_10`–`test_12`: Rich media canvas renderers (video loop, image poster, typography billboard).
* `test_13`–`test_15`: Cloud authentication, Firestore security rules, and fleet targeting.
* `test_16`–`test_17`: Live phone-to-Mac fleet presence discovery, targeted dispatch, and per-device quick clear.

---

## License
MIT License. See [LICENSE](LICENSE) for details.
