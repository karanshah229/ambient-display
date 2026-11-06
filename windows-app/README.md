# Ambient Display for Windows

Windows port of the macOS workstation app (`macos-app/`). It runs from the notification area,
serves the same LAN API on port 8321 that the Android companion uses, and drives every connected monitor.

## Status

| Milestone | Scope | State |
|---|---|---|
| M1 | Core state machine, display coordinator, LAN API (all 18 routes), tray icon, power requests | Done |
| M1 | Network advertising (`_ambientdisplay._tcp`) | Not started; the phone's subnet scan still finds the PC |
| M2 | Full-screen overlays (countdown, billboard, image, video, web) | Not started; a logging placeholder stands in |
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

## Differences from macOS

- Display IDs are 8-hex-digit hashes of the monitor device path, not CoreGraphics display numbers. They stay stable across reboots.
- Ignored displays are matched by ID only. macOS also matched by monitor name, which ignored every monitor of the same model.
- Timed canvases clear the cloud `activeCanvas` field when they expire. On macOS only manual dismissal cleared it.
- Active power requests show in `powercfg /requests` (run elevated) under DISPLAY and SYSTEM, instead of `pmset -g assertions`.
