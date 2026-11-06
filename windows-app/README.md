# Ambient Display for Windows

Windows port of the macOS workstation app (`macos-app/`). It runs from the notification area,
serves the same LAN API on port 8321 that the Android companion uses, and drives every connected monitor.

## Status

| Milestone | Scope | State |
|---|---|---|
| M1 | Core state machine, display coordinator, LAN API (all 18 routes), tray icon, power requests | Done |
| M1 | Network advertising (`_ambientdisplay._tcp`) | Done; verified with the Android app's Auto-Discover |
| M2 | Full-screen overlays (countdown, billboard, image, video, web), ESC/click/Alt+F4 dismissal | Done |
| M3 | Full tray menu, preferences window, launch at login | Not started |
| M4 | Firebase cloud sync and Google sign-in | Not started; cloud routes report a signed-out device |
| M5 | Packaging, firewall rule, Windows E2E harness | Not started |

## Requirements

- Windows 10 or 11
- .NET 10 SDK (`winget install Microsoft.DotNet.SDK.10`)

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

The app has no window. Use the tray icon to start or stop sleep, run the 10-second test, toggle Away Mode,
open the log folder, or quit. Open `http://127.0.0.1:8321/` for a small status page.

The first launch may show a Windows Firewall prompt for port 8321. Allow it on **private** networks so the phone can connect.

The PC announces itself on the local network as `AmbientDisplay-<hostname>._ambientdisplay._tcp`, so the Android app's
**Auto-Discover** finds it without typing an IP. This uses the DNS-SD service built into Windows 10 (1809+) and 11, so no
Bonjour install is needed; the built-in "mDNS (UDP-In)" firewall rule must be enabled (it is by default). The
announcement follows the Wi-Fi/Ethernet adapter that has a default gateway, skips WSL and Hyper-V virtual switches, and
updates when the address changes. TXT records carry `platform=windows`, `device_id`, `name` and `api=1`.

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
