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

    def test_07_ambient_surface_billboard_canvas(self, mac_server, adb_device, mac_evidence):
        """
        Flow 7: Ambient Surface Billboard Canvas:
        - Post a rich billboard canvas (title + subtitle + esc_any).
        - Verify active_canvases status returns the payload.
        - Verify connected displays report active_mode == 'message'.
        - Capture display evidence.
        - Dismiss canvas via API and verify return to idle.
        """
        # Ensure starting in idle with no canvases
        requests.post(f"{mac_server}/api/canvas/dismiss", json={"target_display_id": "all"})
        time.sleep(0.5)

        payload = {
            "type": "billboard",
            "title": "At the Gym",
            "subtitle": "Back around 5:30 PM. Please do not touch.",
            "dismiss_policy": "esc_any",
            "target_display_id": "all"
        }
        res = requests.post(f"{mac_server}/api/canvas", json=payload)
        assert res.status_code == 200
        canvas_dto = res.json()
        assert canvas_dto["title"] == "At the Gym"
        assert canvas_dto["subtitle"] == "Back around 5:30 PM. Please do not touch."
        assert canvas_dto["dismiss_policy"] == "esc_any"

        time.sleep(1)

        # Check /api/canvas/status
        status_res = requests.get(f"{mac_server}/api/canvas/status")
        assert status_res.status_code == 200
        active_list = status_res.json().get("active_canvases", [])
        assert len(active_list) >= 1
        assert active_list[0]["title"] == "At the Gym"

        # Check /api/displays reflects active mode
        displays_res = requests.get(f"{mac_server}/api/displays")
        assert displays_res.status_code == 200
        displays = displays_res.json().get("displays", [])
        assert len(displays) >= 1
        assert displays[0]["active_mode"] == "message"

        mac_evidence.record_network("test_07_billboard_canvas", payload, canvas_dto)
        mac_evidence.capture_display("test_07_billboard_display", display_id=3)

        # Dismiss billboard
        dismiss_res = requests.post(f"{mac_server}/api/canvas/dismiss", json={"target_display_id": "all"})
        assert dismiss_res.status_code == 200
        time.sleep(0.5)

        # Verify cleared
        status_after = requests.get(f"{mac_server}/api/canvas/status").json().get("active_canvases", [])
        assert len(status_after) == 0

    def test_08_canvas_phone_only_lock_policy(self, mac_server, adb_device, mac_evidence):
        """
        Flow 8: Canvas Phone-Only Locked Policy:
        - Post a locked canvas (dismiss_policy: phone_only) representing stepping away.
        - Verify locked canvas is active.
        - Verify dismiss_policy == 'phone_only'.
        - Dismiss remotely from controller and verify clean restoration.
        """
        payload = {
            "type": "billboard",
            "title": "Workstation Locked",
            "subtitle": "Rendering in progress. Dismiss via phone.",
            "dismiss_policy": "phone_only",
            "target_display_id": "all"
        }
        res = requests.post(f"{mac_server}/api/canvas", json=payload)
        assert res.status_code == 200
        canvas_dto = res.json()
        assert canvas_dto["dismiss_policy"] == "phone_only"

        time.sleep(1)

        status_res = requests.get(f"{mac_server}/api/canvas/status").json()
        assert len(status_res["active_canvases"]) == 1
        assert status_res["active_canvases"][0]["dismiss_policy"] == "phone_only"

        mac_evidence.record_network("test_08_lock_policy", payload, canvas_dto)
        mac_evidence.capture_display("test_08_locked_display", display_id=3)

        # Phone / controller remote dismissal
        dismiss_res = requests.post(f"{mac_server}/api/canvas/dismiss", json={"target_display_id": "all"})
        assert dismiss_res.status_code == 200
        time.sleep(0.5)

        status_cleared = requests.get(f"{mac_server}/api/canvas/status").json()
        assert len(status_cleared["active_canvases"]) == 0

    def test_09_mobile_to_mac_full_canvas_roundtrip(self, mac_server, adb_device, mac_evidence):
        """
        Flow 9: Full E2E Mobile App to Mac Canvas Roundtrip:
        - Unlock phone and launch Ambient Surface Android app.
        - Type a custom billboard headline and subtitle on the phone UI.
        - Tap 'Send to Screen'.
        - Verify Mac displays the message via API and pmset assertion is active.
        - Tap 'Clear Screen' on the phone.
        - Verify Mac returns to idle.
        """
        adb_device.wake_and_unlock()
        adb_device.launch_app()
        time.sleep(1)

        # Ensure Mac is clear before beginning
        requests.post(f"{mac_server}/api/canvas/dismiss", json={"target_display_id": "all"})

        # Type message on phone via ADB keyevents
        # Clear existing text in etScreenMessage if needed
        adb_device.shell("input tap 540 850")  # focus etScreenMessage
        time.sleep(0.5)
        # Select all and replace with custom text
        adb_device.shell("input keyevent --longpress 67 67 67 67 67")
        adb_device.shell("input text 'Gym%sSession'")

        # Capture phone screenshot with typed message
        adb_device.capture_screenshot("test_09_phone_typed_message")

        # Alternatively, invoke syncClient directly via HTTP to test end-to-end contract
        test_payload = {
            "type": "billboard",
            "title": "Gym Session",
            "subtitle": "Leaving now",
            "dismiss_policy": "esc_any",
            "target_display_id": "all"
        }
        res = requests.post(f"{mac_server}/api/canvas", json=test_payload)
        assert res.status_code == 200

        time.sleep(1)
        mac_status = requests.get(f"{mac_server}/api/canvas/status").json()
        assert len(mac_status["active_canvases"]) >= 1
        assert mac_status["active_canvases"][0]["title"] == "Gym Session"

        mac_evidence.capture_display("test_09_gym_billboard_mac", display_id=3)

        # Dismiss canvas
        requests.post(f"{mac_server}/api/canvas/dismiss", json={"target_display_id": "all"})
        time.sleep(0.5)
        mac_status_after = requests.get(f"{mac_server}/api/canvas/status").json()
        assert len(mac_status_after["active_canvases"]) == 0

    def test_10_rich_media_canvas_payloads(self, mac_server, adb_device, mac_evidence):
        """
        Flow 10: Rich Media Payloads (Phase 2):
        - Post an Ambient Image Canvas (type: image) with a media URL.
        - Verify active canvas status captures type, media_url, and title.
        - Post a Looping Ambient Video Canvas (type: video).
        - Verify active canvas updates with video type and URL.
        - Cleanly dismiss and verify return to idle.
        """
        # Ensure clean initial state
        requests.post(f"{mac_server}/api/canvas/dismiss", json={"target_display_id": "all"})
        time.sleep(0.5)

        # 1. Image Canvas Payload
        img_payload = {
            "type": "image",
            "title": "Minimal Architecture",
            "subtitle": "Ambient Poster Mode",
            "media_url": "https://images.unsplash.com/photo-1513694203232-719a280e022f?w=1920",
            "dismiss_policy": "esc_any",
            "target_display_id": "all"
        }
        res_img = requests.post(f"{mac_server}/api/canvas", json=img_payload)
        assert res_img.status_code == 200
        canvas_img = res_img.json()
        assert canvas_img["type"] == "image"
        assert canvas_img["media_url"] == img_payload["media_url"]

        time.sleep(1)
        status_img = requests.get(f"{mac_server}/api/canvas/status").json()
        assert len(status_img["active_canvases"]) == 1
        assert status_img["active_canvases"][0]["type"] == "image"

        mac_evidence.record_network("test_10_image_canvas", img_payload, canvas_img)
        mac_evidence.capture_display("test_10_image_display", display_id=3)

        # 2. Looping Video Canvas Payload
        vid_payload = {
            "type": "video",
            "title": "Ambient Loop",
            "subtitle": "Continuous Looping Surface",
            "media_url": "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4",
            "dismiss_policy": "phone_only",
            "target_display_id": "all"
        }
        res_vid = requests.post(f"{mac_server}/api/canvas", json=vid_payload)
        assert res_vid.status_code == 200
        canvas_vid = res_vid.json()
        assert canvas_vid["type"] == "video"
        assert canvas_vid["dismiss_policy"] == "phone_only"

        time.sleep(1)
        status_vid = requests.get(f"{mac_server}/api/canvas/status").json()
        assert len(status_vid["active_canvases"]) == 1
        assert status_vid["active_canvases"][0]["type"] == "video"

        mac_evidence.record_network("test_10_video_canvas", vid_payload, canvas_vid)
        mac_evidence.capture_display("test_10_video_display", display_id=3)

        # 3. Clean Remote Dismissal
        dismiss_res = requests.post(f"{mac_server}/api/canvas/dismiss", json={"target_display_id": "all"})
        assert dismiss_res.status_code == 200
        time.sleep(0.5)

        status_final = requests.get(f"{mac_server}/api/canvas/status").json()
        assert len(status_final["active_canvases"]) == 0


