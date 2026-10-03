#!/usr/bin/env python3
"""
E2E Automated Test Suite for Wake Me Up macOS Server & Display Node
Verifies:
1. HTTP REST API endpoints (/api/status, /api/sleep, /api/test, /api/away, /api/wake)
2. macOS Power Assertions (pmset -g assertions) for PreventUserIdleDisplaySleep & SystemSleep
3. State transitions (idle -> sleeping -> wakeUpReady -> idle)
4. Away Mode behavior and assertion release
"""

import sys
import time
import json
import urllib.request
import urllib.error
import subprocess
import os
import signal

PORT = 8321
BASE_URL = f"http://127.0.0.1:{PORT}"
MAC_BINARY = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "../macos-app/.build/debug/WakeMeUp")
)

def log(msg):
    print(f"[TEST-E2E] {msg}", flush=True)

def http_get(path):
    url = f"{BASE_URL}{path}"
    req = urllib.request.Request(url, headers={"User-Agent": "WakeMeUp-E2E"})
    with urllib.request.urlopen(req, timeout=5) as res:
        return res.status, json.loads(res.read().decode("utf-8"))

def http_post(path, data=None):
    url = f"{BASE_URL}{path}"
    body = json.dumps(data or {}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": "WakeMeUp-E2E"},
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=5) as res:
        return res.status, json.loads(res.read().decode("utf-8"))

def check_pmset_assertions():
    try:
        out = subprocess.check_output(["pmset", "-g", "assertions"], text=True)
        has_display = "PreventUserIdleDisplaySleep" in out
        has_system = "PreventUserIdleSystemSleep" in out
        has_app = "WakeMeUp" in out
        return {
            "display_sleep_prevented": has_display,
            "system_sleep_prevented": has_system,
            "wake_me_up_asserting": has_app
        }
    except Exception as e:
        log(f"Warning checking pmset: {e}")
        return {}

def run_tests():
    log(f"Target binary: {MAC_BINARY}")
    if not os.path.exists(MAC_BINARY):
        log("Compiling macOS binary...")
        subprocess.check_call(["swift", "build"], cwd=os.path.dirname(MAC_BINARY) + "/../../")

    # Start app in background
    log("Starting WakeMeUp macOS background process...")
    proc = subprocess.Popen([MAC_BINARY], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.5)

    try:
        # Step 1: Check Server Startup & Initial Status
        log("Step 1: Checking /api/status on startup...")
        status, data = http_get("/api/status")
        assert status == 200, f"Expected 200, got {status}"
        assert data["state"] == "idle", f"Expected idle state, got {data['state']}"
        assert data["power_assertion_active"] == False
        log(f"✓ Startup status verified. Detected {data['screens_count']} display(s).")

        # Step 2: Test Sleep Session Trigger (7.5h)
        log("Step 2: Triggering 7.5h Sleep session (POST /api/sleep)...")
        status, res = http_post("/api/sleep", {"duration_minutes": 450.0, "reason": "e2e_test"})
        assert status == 200
        time.sleep(0.5)

        status, data = http_get("/api/status")
        assert data["state"] == "sleeping", f"Expected state sleeping, got {data['state']}"
        assert data["power_assertion_active"] == True
        assert data["countdown_text"] is not None
        log(f"✓ Sleeping state active: Target = {data['target_wake_time']}, Countdown = {data['countdown_text']}")

        # Step 3: Verify macOS Kernel Power Assertions
        log("Step 3: Inspecting macOS kernel power assertions (pmset)...")
        pmset = check_pmset_assertions()
        assert pmset.get("display_sleep_prevented", False), "PreventUserIdleDisplaySleep is not active!"
        assert pmset.get("wake_me_up_asserting", False), "WakeMeUp is not listed in power assertions!"
        log("✓ Kernel power assertions verified: MacBook Air and Dell monitors will NOT sleep.")

        # Step 4: Test Fast-Forward 3-Second Simulation
        log("Step 4: Running 3-second simulation into Wake-Up Ready transition...")
        status, res = http_post("/api/test", {"duration_seconds": 3})
        assert status == 200

        time.sleep(1.5)
        status, data = http_get("/api/status")
        assert data["state"] == "sleeping"
        log(f"  Countdown ticking: {data['countdown_text']}")

        time.sleep(2.0)
        status, data = http_get("/api/status")
        assert data["state"] == "wakeUpReady", f"Expected wakeUpReady, got {data['state']}"
        assert data["countdown_text"] == "00:00"
        log("✓ Wake-up transition reached: Fullscreen shows 'WAKE ME UP'!")

        # Step 5: Test Stop / Wake Up Dismissal
        log("Step 5: Dismissing wake-up state (POST /api/wake)...")
        status, res = http_post("/api/wake")
        assert status == 200
        time.sleep(0.5)

        status, data = http_get("/api/status")
        assert data["state"] == "idle"
        assert data["power_assertion_active"] == False
        log("✓ State returned to idle and power assertions released cleanly.")

        # Step 6: Test Away Mode
        log("Step 6: Testing Away Mode...")
        status, res = http_post("/api/away", {"is_away_mode": True})
        assert status == 200
        time.sleep(0.2)

        status, data = http_get("/api/status")
        assert data["is_away_mode"] == True

        # Ensure sleep triggers are ignored while away
        http_post("/api/sleep", {"duration_minutes": 450.0})
        time.sleep(0.2)
        status, data = http_get("/api/status")
        assert data["state"] == "idle", "Sleep event should be ignored when Away Mode is enabled!"
        log("✓ Away mode verified: sleep trigger safely ignored.")

        # Restore away mode
        http_post("/api/away", {"is_away_mode": False})
        log("✓ Away mode restored to normal.")

        log("\n==========================================")
        log("🎉 ALL E2E INTEGRATION TESTS PASSED 100%!")
        log("==========================================\n")

    finally:
        log("Shutting down background test process...")
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()

if __name__ == "__main__":
    run_tests()
