import os
import subprocess
import time
import json
import pytest
import requests

MAC_PORT = 8321
MAC_BASE_URL = f"http://127.0.0.1:{MAC_PORT}"
ARTIFACTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "artifacts"))
MAC_BINARY = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "../macos-app/.build/debug/AmbientDisplay")
)

@pytest.fixture(scope="session", autouse=True)
def setup_artifacts_dir():
    os.makedirs(ARTIFACTS_DIR, exist_ok=True)
    return ARTIFACTS_DIR

@pytest.fixture(scope="session")
def mac_server():
    """Starts the native macOS app and ensures it stays running throughout the test session."""
    # Always ensure latest binary is built
    subprocess.check_call(
        ["swift", "build"],
        cwd=os.path.abspath(os.path.join(os.path.dirname(__file__), "../macos-app"))
    )

    # Check if already running or start fresh
    already_running = False
    try:
        r = requests.get(f"{MAC_BASE_URL}/api/status", timeout=1)
        if r.status_code == 200:
            already_running = True
    except Exception:
        pass

    proc = None
    if not already_running:
        proc = subprocess.Popen([MAC_BINARY], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.5)

    # Ensure healthy
    healthy = False
    for _ in range(10):
        try:
            r = requests.get(f"{MAC_BASE_URL}/api/status", timeout=2)
            if r.status_code == 200:
                healthy = True
                break
        except Exception:
            time.sleep(0.5)

    if not healthy:
        if proc:
            proc.kill()
        pytest.fail("Failed to boot macOS AmbientDisplay server on port 8321")

    yield MAC_BASE_URL

    # Reset server state to idle before session exit
    try:
        requests.post(f"{MAC_BASE_URL}/api/wake", timeout=2)
    except Exception:
        pass

    if proc:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except Exception:
            proc.kill()

@pytest.fixture
def adb_device():
    """Helper class providing deterministic device actions and evidence capture."""
    class DeviceDriver:
        def __init__(self):
            out = subprocess.check_output(["adb", "devices"], text=True)
            lines = [l for l in out.strip().split("\n")[1:] if l.strip() and not l.startswith("*")]
            assert len(lines) > 0, "No ADB device connected!"
            self.device_id = lines[0].split("\t")[0].strip()

        def shell(self, cmd: str) -> str:
            res = subprocess.check_output(["adb", "-s", self.device_id, "shell", cmd], text=True)
            return res.strip()

        def capture_screenshot(self, name: str) -> str:
            target_path = os.path.join(ARTIFACTS_DIR, f"{name}.png")
            with open(target_path, "wb") as f:
                subprocess.check_call(["adb", "-s", self.device_id, "exec-out", "screencap", "-p"], stdout=f)
            return target_path

        def lock_screen(self):
            # Keyevent 26 = Power button
            self.shell("input keyevent 26")
            time.sleep(1)

        def wake_and_unlock(self):
            # Ensure device is awake and display is ON
            for _ in range(3):
                wakefulness = self.shell("dumpsys power | grep mWakefulness=").strip()
                screen_state = self.shell("dumpsys display | grep mScreenState=").strip()
                if "Awake" in wakefulness and "ON" in screen_state:
                    break
                self.shell("input keyevent 224")  # WAKEUP
                time.sleep(0.3)
                self.shell("input keyevent 26")   # Power toggle if needed
                time.sleep(0.3)
            # Dismiss keyguard / swipe up
            self.shell("input swipe 540 2000 540 400")
            time.sleep(0.3)
            self.shell("input keyevent 82")
            time.sleep(0.3)
            self.shell("wm dismiss-keyguard")



        def launch_app(self):
            # Bring activity reliably to foreground without exiting if back pressed
            self.shell("am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000 -n com.ambientdisplay/.MainActivity")
            time.sleep(1)
            # Dismiss soft keyboard if visible using ESC / 111
            self.shell("input keyevent 111")
            time.sleep(0.3)



        def get_bounds_by_id(self, res_id: str):
            import re
            self.shell("uiautomator dump /sdcard/ui_tmp.xml")
            xml = self.shell("cat /sdcard/ui_tmp.xml")
            m = re.search(r'resource-id="[^"]*' + re.escape(res_id) + r'"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml)
            if not m:
                # also check if bounds comes first
                m = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"[^>]*resource-id="[^"]*' + re.escape(res_id) + r'"', xml)
            if m:
                x1, y1, x2, y2 = map(int, m.groups())
                return ((x1 + x2) // 2, (y1 + y2) // 2)
            return None

        def tap_by_id(self, res_id: str) -> bool:
            pt = self.get_bounds_by_id(res_id)
            if pt:
                self.shell(f"input tap {pt[0]} {pt[1]}")
                return True
            return False

        def dump_alarms(self, name: str) -> str:

            target_path = os.path.join(ARTIFACTS_DIR, f"{name}_alarms.txt")
            out = self.shell("dumpsys alarm | grep -C 3 'com.ambientdisplay'")
            with open(target_path, "w") as f:
                f.write(out)
            return out

        def dump_logcat(self, name: str) -> str:
            target_path = os.path.join(ARTIFACTS_DIR, f"{name}_logcat.txt")
            out = self.shell("logcat -d | grep -i 'com.ambientdisplay' | tail -n 50")
            with open(target_path, "w") as f:
                f.write(out)
            return out

    return DeviceDriver()

@pytest.fixture
def mac_evidence():
    """Helper to capture macOS system assertions and network responses."""
    class MacDriver:
        def dump_pmset(self, name: str) -> dict:
            target_path = os.path.join(ARTIFACTS_DIR, f"{name}_pmset.txt")
            out = subprocess.check_output(["pmset", "-g", "assertions"], text=True)
            with open(target_path, "w") as f:
                f.write(out)
            return {
                "PreventUserIdleDisplaySleep": "PreventUserIdleDisplaySleep" in out,
                "PreventUserIdleSystemSleep": "PreventUserIdleSystemSleep" in out,
                "AmbientDisplayActive": "AmbientDisplay" in out
            }

        def record_network(self, name: str, request_data: dict, response_data: dict):
            target_path = os.path.join(ARTIFACTS_DIR, f"{name}_network.json")
            with open(target_path, "w") as f:
                json.dump({"request": request_data, "response": response_data}, f, indent=2)

        def capture_display(self, name: str, display_id: int = 3) -> str:
            target_path = os.path.join(ARTIFACTS_DIR, f"{name}.png")
            try:
                subprocess.check_call(["screencapture", "-x", f"-D{display_id}", target_path])
                return target_path
            except Exception as e:
                print(f"screencapture failed: {e}")
                return ""

    return MacDriver()
