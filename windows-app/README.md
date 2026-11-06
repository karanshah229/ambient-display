# Ambient Display for Windows

Windows port of the macOS workstation app (`macos-app/`). It runs from the notification area,
serves the same LAN API on port 8321 that the Android companion uses, and drives every connected monitor.

## Status

| Milestone | Scope | State |
|---|---|---|
| M1 | Core state machine, display coordinator, LAN API (all 18 routes), tray icon, power requests | Done |
| M1 | Network advertising (`_ambientdisplay._tcp`) | Done; verified with the Android app's Auto-Discover |
| M2 | Full-screen overlays (countdown, billboard, image, video, web), ESC/click/Alt+F4 dismissal | Done |
| M3 | Full tray menu, preferences window, launch at login | Done |
| M4 | Firebase cloud sync and Google sign-in | Done; verified against the live project with the Android app |
| M5 | Packaging (build.ps1, install.ps1), private-network firewall rule, Windows E2E harness, docs | Done (live E2E run pending) |

## Requirements

- Windows 10 or 11
- .NET 10 SDK (`winget install Microsoft.DotNet.SDK.10`)

## Release & install

```bash
pwsh windows-app/build.ps1
```

```bash
powershell -ExecutionPolicy Bypass -File windows-app/dist/AmbientDisplay-1.0.0-win-x64/install.ps1 -LaunchAtLogin
```

`build.ps1` runs the tests and publishes a self-contained, single-file `AmbientDisplay.exe` (about 85 MB, no .NET needed
on the target PC) plus a zip. `install.ps1` works in Windows PowerShell 5.1 and 7 and installs per user to
`%LOCALAPPDATA%\Programs\AmbientDisplay`, with a Start menu shortcut and an Installed apps entry. It asks for admin
approval once, to allow TCP 8321 on private networks only. Options: `-LaunchAtLogin`, `-SkipFirewall`, `-FirewallOnly`,
`-NoStart`, `-Uninstall` and `-Purge`. Regenerate the app icon with `tools/make-icon.ps1`.

## Build, test, run

```bash
dotnet build windows-app/AmbientDisplay.slnx
```

```bash
dotnet test windows-app/AmbientDisplay.slnx
```

```bash
dotnet run --project windows-app/src/AmbientDisplay.App
```

The app lives in the notification area. Its icon shows the state: a monitor when idle, a moon while sleeping, a gold
sun at wake-up time, and a crossed-out monitor in Away Mode. The tooltip shows the target wake time. Right-click for
the menu (start/stop sleep, 10-second test, Away Mode, Start at Login, Google sign-in, Preferences, log folder, quit);
double-click to open **Preferences**. Preferences has six tabs, matching the macOS app:

| Tab | Settings |
|---|---|
| General | Launch at login (per-user Run registry entry, no admin needed), wake time in tooltip, Away Mode |
| Sleep | Target duration, eligible sleep window, auto-push window, inactivity compensation |
| Displays | Which monitors the countdown and canvases may use |
| Ambient | Night / dawn / wake glow colours (#RRGGBB), reset, 10-second test |
| Network | LAN address and port, mDNS advertisement status, status page link |
| Cloud | Google account, this workstation's ID, sync status, devices in your account |

The phone's "open preferences" command (`POST /api/preferences`) opens the same window. For a small status page, open
`http://127.0.0.1:8321/`.

The first launch may show a Windows Firewall prompt for port 8321. Allow it on **private** networks so the phone can connect.

The PC announces itself on the local network as `AmbientDisplay-<hostname>._ambientdisplay._tcp`, so the Android app's
**Auto-Discover** finds it without typing an IP. This uses the DNS-SD service built into Windows 10 (1809+) and 11, so no
Bonjour install is needed; the built-in "mDNS (UDP-In)" firewall rule must be enabled (it is by default). The
announcement follows the Wi-Fi/Ethernet adapter that has a default gateway, skips WSL and Hyper-V virtual switches, and
updates when the address changes. TXT records carry `platform=windows`, `device_id`, `name` and `api=1`.

## Cloud sync (optional)

Without configuration the PC works over local Wi-Fi only. To sync through your own Firebase project:

1. In Google Cloud → APIs & Services → Credentials for the Firebase project, create an OAuth client of type
   **Desktop app**. Google's loopback sign-in flow expects this client type; the iOS client the macOS app uses
   isn't designed for it.
2. Create `%APPDATA%\AmbientDisplay\firebase.json` (outside the repo, never committed):

   ```json
   {
     "projectId": "your-project-id",
     "apiKey": "your Firebase Browser/Web API key",
     "oauthClientId": "....apps.googleusercontent.com",
     "oauthClientSecret": "GOCSPX-..."
   }
   ```

   Environment variables `FIREBASE_PROJECT_ID`, `FIREBASE_API_KEY`, `FIREBASE_CLIENT_ID` and `FIREBASE_CLIENT_SECRET`
   override the file.
3. Choose **☁ Sign In with Google…** in the tray menu and finish in the browser.

What it does, matching the macOS app:

- Signs in with Google in the browser and returns to a random local port, with PKCE and a `state` check, then
  exchanges the result for a Firebase session. The refresh token is stored encrypted with DPAPI under
  `%APPDATA%\AmbientDisplay\secrets`; ID tokens refresh automatically.
- Registers `users/{uid}/devices/machine_<hostname>` with `deviceType: "machine"` and sends a heartbeat every 60 s,
  so the phone lists the PC as ONLINE. On quit or sign-out the device is marked `offline`.
- Listens live to the fleet over Firestore. A canvas sent through the cloud appears on the PC, and clearing it from
  the phone removes it. Dismissing on the PC (ESC, click, timer, or a Wi-Fi dismiss) clears `activeCanvas` in Firestore.
- Syncs preferences both ways through `users/{uid}.preferences`, without echoing changes back.
- Reconnects dropped listeners with backoff and a fresh token.

## Layout

```
windows-app/
  src/AmbientDisplay.Core/   net10.0: SleepSession, AppState, DisplayCoordinator, DTOs, ApiRouter, Kestrel host
  src/AmbientDisplay.App/    net10.0-windows WPF: composition root, tray, Win32 displays and power requests
  tests/AmbientDisplay.Tests/ xUnit: ports of the macOS tests plus API contract tests
```

## Files on disk

| What | Where |
|---|---|
| Preferences (same keys as macOS UserDefaults) | `%APPDATA%\AmbientDisplay\settings.json` |
| Log | `%LOCALAPPDATA%\AmbientDisplay\logs\ambient-display.log` |

## Overlay snapshots

Render every overlay scene to PNG without opening windows (the counterpart of the macOS `RenderSnapshots` tool):

```bash
windows-app/src/AmbientDisplay.App/bin/Debug/net10.0-windows/AmbientDisplay.exe --render-snapshots snapshots
```

## Differences from macOS

- Display IDs are 8-hex-digit hashes of the monitor device path, not CoreGraphics display numbers. They stay stable across reboots.
- Ignored displays are matched by ID only. macOS also matched by monitor name, which ignored every monitor of the same model.
- Timed canvases clear the cloud `activeCanvas` field when they expire. On macOS only manual dismissal cleared it.
- Active power requests show in `powercfg /requests` (run elevated) under DISPLAY and SYSTEM, instead of `pmset -g assertions`.
- Overlays cannot appear over the Windows lock screen. macOS draws above its lock screen; Windows allows nothing above the secure desktop.
- Web dashboards fill the area between the status bars, with the canvas title in the header. On macOS the title is drawn over the page; WebView2 is a native window, so WPF can't draw on top of it.
- ESC works from any app only while overlays cover every monitor. When a monitor is uncovered, ESC reaches an overlay only if it has focus, so typing on the free monitor is never intercepted.
- Alt+F4 on an overlay follows the dismiss policy, so a `phone_only` canvas can't be closed that way.
- Image, video and web canvases only load `http` and `https` URLs.
- Video uses the Windows media stack (MP4/H.264 works out of the box). Web dashboards need the Microsoft Edge WebView2 Runtime, which ships with Windows 11.
