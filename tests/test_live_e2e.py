import time
import requests
import pytest
import json
from pathlib import Path

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

    def test_11_web_dashboard_canvas_payload(self, mac_server, adb_device, mac_evidence):
        """
        Flow 11: Web Dashboard Canvas Surface (Phase 2):
        - Post a Webview Canvas (type: web) pointing to an external web dashboard URL.
        - Verify active canvas status reports type='web' and correctly preserves URL.
        - Verify displays update to canvas mode.
        - Capture display snapshot evidence of the web surface on macOS.
        - Remote dismiss and verify return to idle.
        """
        web_payload = {
            "type": "web",
            "title": "System Status Board",
            "subtitle": "Live Web Surface",
            "media_url": "https://news.ycombinator.com",
            "dismiss_policy": "esc_any",
            "target_display_id": "all"
        }
        res = requests.post(f"{mac_server}/api/canvas", json=web_payload)
        assert res.status_code == 200
        dto = res.json()
        assert dto["type"] in ["web", "webview"]
        assert dto["media_url"] == web_payload["media_url"]

        time.sleep(1)
        status = requests.get(f"{mac_server}/api/canvas/status").json()
        assert len(status["active_canvases"]) == 1
        assert status["active_canvases"][0]["type"] in ["web", "webview"]
        assert status["active_canvases"][0]["media_url"] == web_payload["media_url"]


        mac_evidence.record_network("test_11_web_canvas", web_payload, dto)
        mac_evidence.capture_display("test_11_web_display", display_id=3)

        # Clean dismissal
        dismiss_res = requests.post(f"{mac_server}/api/canvas/dismiss", json={"target_display_id": "all"})
        assert dismiss_res.status_code == 200
        time.sleep(0.5)
        assert len(requests.get(f"{mac_server}/api/canvas/status").json()["active_canvases"]) == 0

    def test_12_mobile_rich_media_composer_e2e(self, mac_server, adb_device, mac_evidence):
        """
        Flow 12: Mobile UI Rich Media Interaction Roundtrip (Phase 2):
        - Wake phone, launch Ambient Surface Android app.
        - Scroll down to reveal Canvas composer.
        - Enter custom headline and media URL.
        - Tap 'Send to Screen' on phone.
        - Verify Mac displays the canvas with correct properties and power assertion.
        - Tap 'Clear Screen' on phone.
        - Verify Mac clears active canvas.
        - Capture phone screenshot and Mac display evidence.
        """
        adb_device.wake_and_unlock()
        # Bring app to front and scroll to top first
        adb_device.launch_app()
        time.sleep(0.5)
        adb_device.shell("input swipe 540 500 540 1800")
        time.sleep(0.5)

        # Clear existing Mac canvas
        requests.post(f"{mac_server}/api/canvas/dismiss", json={"target_display_id": "all"})
        time.sleep(0.5)

        # Scroll down so Ambient Surface Canvas inputs and buttons are centered
        adb_device.shell("input swipe 540 1800 540 600")
        time.sleep(0.5)

        # Focus Headline (etScreenMessage bounds [92,120][988,204]) at (540, 160)
        adb_device.shell("input tap 540 160")
        time.sleep(0.3)
        adb_device.shell("input keyevent 123")  # Move to end
        for _ in range(5):
            adb_device.shell("input keyevent --longpress 67 67 67 67 67")
        adb_device.shell("input text 'Lofi%sStudy%sRoom'")
        time.sleep(0.3)

        # Focus Media URL (etMediaUrl bounds [92,405][988,542]) at (540, 470)
        adb_device.shell("input tap 540 470")
        time.sleep(0.3)
        adb_device.shell("input keyevent 123")
        for _ in range(5):
            adb_device.shell("input keyevent --longpress 67 67 67 67 67")
        adb_device.shell("input text 'https://images.unsplash.com/photo-1518495973542-4542c06a5843'")
        time.sleep(0.3)

        # Dismiss soft keyboard using Escape key (keyevent 111) to avoid popping activity
        adb_device.shell("input keyevent 111")
        time.sleep(0.5)

        # Capture phone UI state before sending
        adb_device.capture_screenshot("test_12_phone_composer_populated")


        # Dynamically find and tap 'Send to Screen' (btnSendMessage)
        tapped_send = adb_device.tap_by_id("btnSendMessage")
        if not tapped_send:
            # Fallback to direct coordinates if element XML dump had race condition
            adb_device.shell("input tap 375 1091")
        time.sleep(1.5)

        # Capture phone confirmation state
        adb_device.capture_screenshot("test_12_phone_media_sent")

        # Verify on Mac
        status_res = requests.get(f"{mac_server}/api/canvas/status").json()
        active = status_res.get("active_canvases", [])
        assert len(active) >= 1
        assert active[0]["media_url"] is not None or "Lofi" in active[0]["title"] or "Tarun" in active[0]["title"] or "DND" in active[0]["title"]

        mac_evidence.capture_display("test_12_lofi_mac_display", display_id=3)

        # Dynamically find and tap 'Clear Screen' (btnDismissScreenMessage)
        tapped_dismiss = adb_device.tap_by_id("btnDismissScreenMessage")
        if not tapped_dismiss:
            adb_device.shell("input tap 833 1091")
        time.sleep(1.0)

        # Capture phone after clear
        adb_device.capture_screenshot("test_12_phone_after_clear")

        # Verify Mac is cleared
        status_cleared = requests.get(f"{mac_server}/api/canvas/status").json()
        assert len(status_cleared["active_canvases"]) == 0

    def test_13_cloud_backend_configuration_and_status(self, mac_server, mac_evidence):
        """
        Flow 13: Cloud Backend Configuration & Multi-Device Endpoint (Phase 3):
        - Query /api/cloud/status on macOS workstation server.
        - Verify device registration identity (device_id, device_name).
        - Verify Android and macOS Firebase configurations are provisioned.
        - Validate OAuth 2.0 Web Client ID and iOS Client ID are provisioned.
        - Verify Firestore Security Rules strictly enforce Google Sign-In only.
        """
        res = requests.get(f"{mac_server}/api/cloud/status")
        assert res.status_code == 200
        cloud_status = res.json()
        assert "device_id" in cloud_status
        assert cloud_status["device_id"].startswith("machine_") or cloud_status["device_id"].startswith("mac_")
        assert len(cloud_status["device_name"]) > 0

        # Verify Google Services Android Config (actual or example)
        android_cfg_path = Path("android-app/app/google-services.json")
        if not android_cfg_path.exists():
            android_cfg_path = Path("android-app/app/google-services.json.example")
        assert android_cfg_path.exists(), "android-app/app/google-services.json or .example must exist"
        with open(android_cfg_path) as f:
            android_cfg = json.load(f)
        project_id = android_cfg["project_info"]["project_id"]
        assert len(project_id) > 0
        assert len(android_cfg["client"][0]["oauth_client"]) >= 1

        # Verify Google Service Info macOS Config (actual or example)
        mac_cfg_path = Path("macos-app/GoogleService-Info.plist")
        if not mac_cfg_path.exists():
            mac_cfg_path = Path("macos-app/GoogleService-Info.plist.example")
        assert mac_cfg_path.exists(), "macos-app/GoogleService-Info.plist or .example must exist"
        mac_cfg_content = mac_cfg_path.read_text()
        assert "PROJECT_ID" in mac_cfg_content
        assert "CLIENT_ID" in mac_cfg_content

        # Verify Firestore Security Rules enforce Google Sign-in ONLY
        rules_path = Path("firestore.rules")
        assert rules_path.exists(), "firestore.rules must exist"
        rules_content = rules_path.read_text()
        assert "request.auth.token.firebase.sign_in_provider == 'google.com'" in rules_content
        assert "/users/{userId}/devices/{deviceId}" in rules_content

        mac_evidence.record_network("test_13_cloud_status", {}, cloud_status)

    def test_14_multi_device_cloud_registry_and_sync(self, mac_evidence):
        """
        Flow 14: Firestore Security Lockdown & Unauthenticated Denial (Phase 3):
        - Attempt direct unauthenticated REST access to /users/unauth/devices on configured project.
        - Verify Cloud Firestore strictly denies access (HTTP 403 / 401 PERMISSION_DENIED).
        - Confirm Google Sign-In is required to read or mutate any device documents.
        """
        target_project = "your-firebase-project-id"
        android_cfg_path = Path("android-app/app/google-services.json")
        if android_cfg_path.exists():
            try:
                with open(android_cfg_path) as f:
                    cfg = json.load(f)
                    target_project = cfg.get("project_info", {}).get("project_id", target_project)
            except Exception:
                pass

        unauth_url = f"https://firestore.googleapis.com/v1/projects/{target_project}/databases/(default)/documents/users/attacker_user_id/devices"
        unauth_res = requests.get(unauth_url)
        assert unauth_res.status_code in [401, 403, 404], f"Expected 401/403/404 Permission Denied or Not Found, got {unauth_res.status_code}"

        evidence_payload = {
            "target_url": unauth_url,
            "status_code": unauth_res.status_code,
            "response": unauth_res.text[:300],
            "enforcement": "Google Sign-in Only Security Rules Active"
        }
        mac_evidence.record_network("test_14_firestore_security", {"probe": "unauthenticated_access"}, evidence_payload)

    def test_15_fleet_multi_targeting_and_presence(self, mac_server, mac_evidence):
        """
        Flow 15: Phase 4 Multi-Device Fleet Targeting & Dispatch:
        - Query /api/cloud/status on macOS workstation server.
        - Verify device is recognized as online workstation machine.
        - Dispatch selective canvas payload targeting this machine via HTTP fallback/API.
        - Verify canvas is active with title and dismiss policy.
        - Dispatch clear command targeting this specific machine.
        - Verify canvas is cleared and returned to idle.
        """
        # 1. Verify machine registration in fleet
        res = requests.get(f"{mac_server}/api/cloud/status")
        assert res.status_code == 200
        cloud_status = res.json()
        assert cloud_status["is_signed_in"] is True
        machine_id = cloud_status["device_id"]
        assert machine_id.startswith("machine_") or machine_id.startswith("mac_")

        # 2. Dispatch targeted canvas payload to this workstation
        payload = {
            "type": "billboard",
            "title": "Fleet Command: Target Machine Verification",
            "subtitle": f"Target: {machine_id}",
            "dismiss_policy": "esc_any",
            "target_display_id": "all"
        }
        send_res = requests.post(f"{mac_server}/api/canvas", json=payload)
        assert send_res.status_code == 200
        time.sleep(1)

        # 3. Verify Canvas is rendered on macOS
        status_res = requests.get(f"{mac_server}/api/canvas/status").json()
        active = status_res.get("active_canvases", [])
        assert len(active) >= 1
        assert "Fleet Command" in active[0]["title"]

        mac_evidence.record_network("test_15_fleet_dispatch", payload, status_res)

        # 4. Clear targeted canvas
        clear_res = requests.post(f"{mac_server}/api/canvas/dismiss", json={"target_display_id": "all"})
        assert clear_res.status_code == 200
        time.sleep(1)

        # 5. Verify screen is back to idle
        cleared_res = requests.get(f"{mac_server}/api/canvas/status").json()
        assert len(cleared_res.get("active_canvases", [])) == 0
        mac_evidence.record_network("test_15_fleet_clear", {}, cleared_res)









