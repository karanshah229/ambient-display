# Wake Me Up ⏰💤

> An intelligent, multi-monitor ambient sleep timer and automatic alarm system.

When you fall asleep reading or streaming late at night, **Wake Me Up** detects when you actually fell asleep, compensates for screen timeouts, and broadcasts a high-visibility 7.5-hour countdown across your desk monitors (e.g. Dell P2722H & S2740L) so household members walking into the room know exactly when you've had a full night's rest (5 complete 90-minute sleep cycles).

At target wake-up time, your monitors switch to an unmistakable **"Wake me up!"** visual cue, while your phone sounds the audible alarm. The Mac stays silent.

---

## Architecture Overview

```
┌──────────────────────────────────────────────┐
│           Android Phone (OnePlus)            │
│  • Foreground Service (OOM killer immune)    │
│  • Accessibility Watchdog (OxygenOS proof)   │
│  • Inactivity Compensator (dynamic timeout)  │
│  • Midnight Glance Filter (5-min threshold)  │
│  • Hardware RTC AlarmManager (phone rings)   │
└──────────────────────┬───────────────────────┘
                       │ HTTP / Wi-Fi (:8321)
                       ▼
┌──────────────────────────────────────────────┐
│             MacBook Air (macOS)              │
│  • Native Menu Bar Utility (NSStatusItem)    │
│  • Native REST Server (Network.framework)    │
│  • Power Assertions (Prevents Display Sleep) │
│  • Mirrored Fullscreen Across All Displays:  │
│    - Dell P2722H                             │
│    - Dell S2740L                             │
│    - Built-in Retina Display                 │
└──────────────────────────────────────────────┘
```

---

## Key Features

### 1. Smart Inactivity Compensator (Netflix / Reading Gap)
* If you fall asleep streaming or reading, OnePlus OS turns the screen off after your screen-off timeout (e.g. 30 minutes).
* The compensator checks `Settings.System.SCREEN_OFF_TIMEOUT` dynamically (never hardcoded) and compares it with your last active touch event via `UsageStatsManager`.
* If you locked the phone manually with the power button $\rightarrow$ **0 minutes deducted**.
* If the screen turned off due to inactivity $\rightarrow$ **Deducts the 30-minute idle period** so you get full credit for when you actually fell asleep!

### 2. Midnight Glance Filter (5-Minute Threshold)
* Waking up at 3 AM to check the time or drink water shouldn't reset your sleep timer.
* Any unlock duration $< 5$ minutes is ignored as a quick glance.
* If you stay active for $> 5$ minutes, an actionable notification appears: *"Still sleeping? [Keep Alarm] [Reset Bedtime to Now]"*.

### 3. MacBook Air Sleep Immunity
* Solves the notorious macOS issue where background apps get throttled by **App Nap** or displays turn off.
* Uses macOS kernel `IOPMAssertions` (`PreventUserIdleDisplaySleep` and `PreventUserIdleSystemSleep`) while an active session runs.
* Released automatically when you wake up or when **Away Mode** is enabled.

### 4. Display UI Optimized for Across-the-Room Visibility
* **Dual-mode countdown:**
  * During the night ($> 5\text{ min}$ remaining): updates on a **minute basis** (`5h 42m remaining`) to avoid distracting second-ticking in a dark room.
  * Final 5 minutes: dynamically switches to **seconds** (`04:59` $\rightarrow$ `00:00`).
* **Deep night adaptive dimming:** Deep amber/ember low-luminescence typography on pure black background. Transitions smoothly to warm dawn light in the morning.
* **Target reached:** Huge emerald/gold banner: **`WAKE ME UP`**.
* **Mirroring:** Dynamically handles 1, 2, or laptop-only screens (`Dell P2722H`, `Dell S2740L`).

---

## macOS App Setup

### Prerequisites
* macOS 13.0+
* Xcode or Command Line Tools (`swift`)

### Build & Run
```bash
cd macos-app

# 1. Run unit tests
make test

# 2. Run app directly
make run

# 3. Create standalone .app bundle (build/WakeMeUp.app)
make bundle
```

### Menu Bar Controls
* **Status indicator:** Shows idle, current countdown, or target wake time in the menu bar.
* **Manual Sleep:** One-click trigger for a manual 7.5h session.
* **10s Test Preview:** Fast-forwards the entire experience so you can preview the multi-monitor display and transitions.
* **Away Mode:** Master toggle to disable monitor displays when traveling or staying elsewhere.

---

## Android App Setup (OnePlus / OxygenOS)

### Prerequisites
* Android 8.0+ (API 26+)
* Android Studio / Gradle

### OnePlus Immunity Configuration
OnePlus and ColorOS are notoriously aggressive with background apps. To guarantee 100% reliability, four quick toggles are provided directly in the app's setup card:
1. **Battery Optimization:** Tap `1. Disable Battery Optimization` $\rightarrow$ select "Don't optimize" / "Unrestricted".
2. **Usage Access:** Tap `2. Grant Usage Access` $\rightarrow$ enable "Wake Me Up" (allows calculating when Netflix stopped).
3. **Accessibility Watchdog:** Tap `3. Enable Watchdog` $\rightarrow$ turn ON "Wake Me Up" (exempts the app from OxygenOS process killers).
4. **Auto-Launch:** Tap `4. OnePlus Auto-Launch Manager` $\rightarrow$ enable "Allow auto-launch" and "Allow secondary launch".
5. *(Optional)* In the OnePlus App Switcher, tap the three dots on the app card and select **Lock**.

---

## End-to-End (E2E) Testing

An automated test suite is included in `scripts/test_e2e.py`:
```bash
python3 scripts/test_e2e.py
```

This verifies:
1. REST API contracts (`/api/status`, `/api/sleep`, `/api/test`, `/api/wake`, `/api/away`).
2. macOS `pmset -g assertions` kernel power management locks.
3. Multi-monitor mirror rendering.
4. State transitions from idle $\rightarrow$ sleeping $\rightarrow$ final 5-minute seconds mode $\rightarrow$ wake up ready.
5. Away Mode prevention logic.

---

## License
MIT License. See [LICENSE](LICENSE) for details.
