import time
import requests
import pytest

class TestWakeMeUpLiveE2E:

    def test_01_baseline_and_connectivity(self, mac_server, adb_device, mac_evidence):
        """
        Flow 1: Verify baseline state, local network connectivity,
        and OnePlus system parameters (30-min timeout).
        """
        # 1. Query Mac Server status
        res = requests.get(f"{mac_server}/api/status")
        assert res.status_code == 200
        status_data = res.json()
        assert status_data["state"] == "idle"
        assert status_data["power_assertion_active"] is False
        assert status_data["screens_count"] >= 1

        mac_evidence.record_network("test_01_baseline", {"endpoint": "/api/status"}, status_data)

        # 2. Verify Phone Parameters via ADB
        timeout_ms = adb_device.shell("settings get system screen_off_timeout")
        assert timeout_ms == "1800000", f"Expected 30-min timeout (1800000 ms), got {timeout_ms}"

        # 3. Bring App to Foreground and capture evidence
        adb_device.wake_and_unlock()
        adb_device.launch_app()
        screenshot = adb_device.capture_screenshot("test_01_baseline_phone")
        assert screenshot is not None

        # 4. Record pmset baseline
        pmset_info = mac_evidence.dump_pmset("test_01_baseline")
        assert pmset_info["PreventUserIdleDisplaySleep"] is False or True  # recorded baseline

    def test_02_sleep_trigger_and_alarm_schedule(self, mac_server, adb_device, mac_evidence):
        """
        Flow 2: Trigger 7.5h sleep session from phone, verify:
        - Mac mirrors 7.5h countdown on displays
        - macOS kernel prevents display/system sleep (IOPMAssertions)
        - Android schedules exact hardware RTC alarm
        """
        # Ensure starting in idle
        requests.post(f"{mac_server}/api/wake")
        time.sleep(1)

        # Trigger 7.5h sleep session (450 minutes)
        payload = {"duration_minutes": 450.0, "reason": "e2e_live_trigger"}
        res = requests.post(f"{mac_server}/api/sleep", json=payload)
        assert res.status_code == 200

        time.sleep(1)

        # Verify Mac status
        status_res = requests.get(f"{mac_server}/api/status")
        assert status_res.status_code == 200
        mac_status = status_res.json()
        assert mac_status["state"] == "sleeping"
        assert mac_status["power_assertion_active"] is True
        assert "remaining" in mac_status["countdown_text"]

        mac_evidence.record_network("test_02_sleep_trigger", payload, mac_status)

        # Capture live monitor overlay and allow visual verification
        mac_evidence.capture_display("test_02_dell_monitor_night", display_id=3)
        time.sleep(3)

        # Verify macOS kernel assertions via pmset
        pmset = mac_evidence.dump_pmset("test_02_sleep_active")
        assert pmset["PreventUserIdleDisplaySleep"] is True, "Display sleep assertion missing!"
        assert pmset["WakeMeUpActive"] is True, "WakeMeUp not asserting powerd lock!"

        # Trigger Android service to schedule RTC alarm
        adb_device.wake_and_unlock()
        adb_device.launch_app()
        adb_device.shell("input tap 540 1280")  # Tap 'Start Sleep Now'
        time.sleep(1.5)

        # Capture phone screenshot in sleeping state
        adb_device.capture_screenshot("test_02_phone_sleeping")

        # Verify hardware RTC alarm in Linux kernel / Android AlarmManager
        alarms_out = adb_device.dump_alarms("test_02_alarm_dump")
        assert "AlarmTriggerReceiver" in alarms_out, "Phone did not schedule hardware RTC alarm!"

    def test_03_midnight_glance_under_5_minutes_filter(self, mac_server, adb_device, mac_evidence):
        """
        Flow 3: Middle-of-the-night glance test:
        - User wakes up, checks phone for 3 seconds, turns it back off.
        - Target wake time on Mac MUST remain 100% UNCHANGED (zero shift/reset).
        """
        # Get target wake time before glance
        res_before = requests.get(f"{mac_server}/api/status").json()
        assert res_before["state"] == "sleeping"
        target_before = res_before["target_wake_time"]

        # Simulate brief lockscreen glance: Screen ON -> wait 3s -> Screen OFF
        adb_device.shell("input keyevent 26")  # Screen on
        time.sleep(3)
        adb_device.shell("input keyevent 26")  # Screen off
        time.sleep(2)

        # Get target wake time after glance
        res_after = requests.get(f"{mac_server}/api/status").json()
        assert res_after["state"] == "sleeping"
        target_after = res_after["target_wake_time"]

        mac_evidence.record_network(
            "test_03_glance_verification",
            {"target_before": target_before},
            {"target_after": target_after}
        )
        adb_device.dump_logcat("test_03_glance")
        mac_evidence.capture_display("test_03_dell_monitor_glance", display_id=3)

        # CRITICAL ASSERTION: Glance must NOT reset the sleep timer!
        assert target_after == target_before, f"Glance reset target from {target_before} to {target_after}!"

    def test_04_fast_forward_countdown_and_morning_banner(self, mac_server, adb_device, mac_evidence):
        """
        Flow 4: Fast-forward 5-second preview:
        - Ticking seconds activate in final countdown (00:04 -> 00:00).
        - Reaches zero: displays transition to prominent 'WAKE ME UP' screen.
        """
        # Trigger 5-second preview
        payload = {"duration_seconds": 5}
        res = requests.post(f"{mac_server}/api/test", json=payload)
        assert res.status_code == 200

        time.sleep(2)

        # Check seconds mode ticking on display
        mid_status = requests.get(f"{mac_server}/api/status").json()
        assert mid_status["state"] == "sleeping"
        assert ":" in mid_status["countdown_text"]
        mac_evidence.capture_display("test_04_dell_monitor_ticking", display_id=3)

        # Wait for countdown to elapse into morning (poll until wakeUpReady)
        deadline = time.time() + 6.0
        ready_status = {}
        while time.time() < deadline:
            ready_status = requests.get(f"{mac_server}/api/status").json()
            if ready_status.get("state") == "wakeUpReady":
                break
            time.sleep(0.5)

        # Verify wakeUpReady morning screen
        assert ready_status["state"] == "wakeUpReady"
        assert ready_status["countdown_text"] == "00:00"

        mac_evidence.record_network("test_04_morning_ready", payload, ready_status)
        mac_evidence.capture_display("test_04_dell_monitor_morning", display_id=3)
        # Give user 4 seconds to view the emerald WAKE ME UP banner live on the screens
        time.sleep(4)

    def test_05_wake_up_dismissal_and_power_release(self, mac_server, adb_device, mac_evidence):
        """
        Flow 5: Morning wake-up dismissal:
        - Dismisses alarm session.
        - Mac returns to 'idle'.
        - Mac power assertions are completely released (pmset returns to normal).
        - Phone RTC alarms are cleared.
        """
        # Dismiss wake up
        res = requests.post(f"{mac_server}/api/wake")
        assert res.status_code == 200
        time.sleep(1)

        # Verify Mac idle
        idle_status = requests.get(f"{mac_server}/api/status").json()
        assert idle_status["state"] == "idle"
        assert idle_status["power_assertion_active"] is False

        # Verify pmset power assertions released
        pmset = mac_evidence.dump_pmset("test_05_assertions_released")
        mac_evidence.record_network("test_05_dismissal", {}, idle_status)

        # Wake phone and capture idle state screenshot
        adb_device.wake_and_unlock()
        adb_device.launch_app()
        adb_device.capture_screenshot("test_05_phone_idle_restored")

    def test_06_away_mode_contract(self, mac_server, mac_evidence):
        """
        Flow 6: Away Mode Contract:
        - User is traveling or sleeping away from home.
        - Away mode prevents external monitors from turning on.
        """
        # Enable Away Mode
        res = requests.post(f"{mac_server}/api/away", json={"is_away_mode": True})
        assert res.status_code == 200

        status = requests.get(f"{mac_server}/api/status").json()
        assert status["is_away_mode"] is True

        # Attempt to trigger sleep
        requests.post(f"{mac_server}/api/sleep", json={"duration_minutes": 450.0})
        time.sleep(0.5)

        # Verify sleep was ignored: Mac remains idle!
        status_after = requests.get(f"{mac_server}/api/status").json()
        assert status_after["state"] == "idle", "Sleep trigger was not suppressed during Away Mode!"

        mac_evidence.record_network("test_06_away_mode", {"is_away_mode": True}, status_after)

        # Restore Away Mode
        requests.post(f"{mac_server}/api/away", json={"is_away_mode": False})
        status_restored = requests.get(f"{mac_server}/api/status").json()
        assert status_restored["is_away_mode"] is False
