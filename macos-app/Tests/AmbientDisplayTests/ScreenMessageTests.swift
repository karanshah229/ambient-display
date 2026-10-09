import XCTest
@testable import AmbientDisplayCore
import AppKit

@MainActor
final class ScreenMessageTests: XCTestCase {

    override func setUp() async throws {
        AppState.shared.isAwayMode = false
        AppState.shared.ignoredDisplayIDs.removeAll()
        AppState.shared.ignoredDisplayNames.removeAll()
        AppState.shared.ignoredDisplayUUIDs.removeAll()
        AppState.shared.stopSleep()
        WindowManager.shared.hideAllWindows()
    }

    override func tearDown() async throws {
        AppState.shared.isAwayMode = false
        AppState.shared.ignoredDisplayIDs.removeAll()
        AppState.shared.ignoredDisplayNames.removeAll()
        AppState.shared.ignoredDisplayUUIDs.removeAll()
        AppState.shared.stopSleep()
        WindowManager.shared.hideAllWindows()
    }

    func testDisplayDTOEncodingAndDecoding() throws {
        let displays = [
            DisplayInfoDTO(id: "1", name: "Dell P2722HE", is_main: true, width: 1920, height: 1080, active_mode: "idle", is_ignored: false),
            DisplayInfoDTO(id: "2", name: "Built-in Retina", is_main: false, width: 1470, height: 956, active_mode: "sleeping", is_ignored: true)
        ]
        let payload = DisplaysResponsePayload(displays: displays)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(DisplaysResponsePayload.self, from: data)

        XCTAssertEqual(decoded.displays.count, 2)
        XCTAssertEqual(decoded.displays[0].id, "1")
        XCTAssertEqual(decoded.displays[0].name, "Dell P2722HE")
        XCTAssertTrue(decoded.displays[0].is_main)
        XCTAssertEqual(decoded.displays[1].active_mode, "sleeping")
        XCTAssertTrue(decoded.displays[1].is_ignored)
    }

    func testPostMessagePayloadEncodingAndDecoding() throws {
        let payload = PostMessageRequestPayload(text: "Meeting at 5:00 PM", target_display_id: "3", duration_seconds: 30)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(PostMessageRequestPayload.self, from: data)

        XCTAssertEqual(decoded.text, "Meeting at 5:00 PM")
        XCTAssertEqual(decoded.target_display_id, "3")
        XCTAssertEqual(decoded.duration_seconds, 30)
    }

    func testShowMessageAndDismissLifecycle() {
        let wm = WindowManager.shared

        // Initially no active messages
        XCTAssertFalse(wm.hasActiveMessages())

        // Show message
        let activeDto = wm.showMessage(text: "Hello World", targetDisplayId: "all", durationSeconds: 0)
        XCTAssertEqual(activeDto.text, "Hello World")
        XCTAssertEqual(activeDto.target_display_id, "all")
        XCTAssertTrue(wm.hasActiveMessages())

        let list = wm.getActiveMessagesList()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].text, "Hello World")

        // Connected displays report active_mode == "message"
        let displays = wm.getConnectedDisplays()
        if let active = displays.first(where: { !$0.is_ignored }) {
            XCTAssertEqual(active.active_mode, "message")
        }

        // Dismiss message
        wm.dismissMessage(targetDisplayId: "all")
        XCTAssertFalse(wm.hasActiveMessages())

        let displaysAfter = wm.getConnectedDisplays()
        if let activeAfter = displaysAfter.first(where: { !$0.is_ignored }) {
            XCTAssertEqual(activeAfter.active_mode, "idle")
        }
    }

    func testMutualExclusionAndReversionToSleep() {
        let appState = AppState.shared
        let wm = WindowManager.shared

        // Start active sleep session
        appState.startSleep(bedtime: Date(), durationMinutes: 450.0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(appState.state, .sleeping)

        let displaysSleep = wm.getConnectedDisplays()
        if let activeSleep = displaysSleep.first(where: { !$0.is_ignored }) {
            XCTAssertEqual(activeSleep.active_mode, "sleeping")
        }

        // Send a custom message while sleep is active
        wm.showMessage(text: "Water the plants!", targetDisplayId: "all")
        XCTAssertTrue(wm.hasActiveMessages())

        let displaysMsg = wm.getConnectedDisplays()
        if let activeMsg = displaysMsg.first(where: { !$0.is_ignored }) {
            XCTAssertEqual(activeMsg.active_mode, "message", "Message must override sleep on targeted screen")
        }

        // Dismiss message -> MUST REVERT TO SLEEP COUNTDOWN!
        wm.dismissMessage(targetDisplayId: "all")
        XCTAssertFalse(wm.hasActiveMessages())
        XCTAssertEqual(appState.state, .sleeping, "Sleep state must remain active")

        let displaysReverted = wm.getConnectedDisplays()
        if let activeReverted = displaysReverted.first(where: { !$0.is_ignored }) {
            XCTAssertEqual(activeReverted.active_mode, "sleeping", "Screen must revert back to sleep display")
        }

        // Stop sleep -> reverts to idle
        appState.stopSleep()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(appState.state, .idle)

        let displaysIdle = wm.getConnectedDisplays()
        if !displaysIdle.isEmpty {
            XCTAssertEqual(displaysIdle[0].active_mode, "idle")
        }
    }

    func testUniversalDismissalDismissesOnAllScreens() {
        let appState = AppState.shared
        let wm = WindowManager.shared

        // Show a message on all screens
        wm.showMessage(text: "Important Notice", targetDisplayId: "all")
        XCTAssertTrue(wm.hasActiveMessages())

        // Dismiss targetDisplayId: "all" clears active messages completely
        wm.dismissMessage(targetDisplayId: "all")
        XCTAssertFalse(wm.hasActiveMessages())

        for display in wm.getConnectedDisplays() {
            XCTAssertEqual(display.active_mode, "idle")
        }

        // Now test alarm clock / sleep dismissal across all screens
        appState.startSleep(bedtime: Date(), durationMinutes: 450.0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(appState.state, .sleeping)

        // Stopping sleep resets all displays to idle
        appState.stopSleep()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(appState.state, .idle)

        for display in wm.getConnectedDisplays() {
            XCTAssertEqual(display.active_mode, "idle")
        }
    }

    func testCanvasShowAndDismissLifecycle() throws {
        let wm = WindowManager.shared

        let canvasDto = wm.showCanvas(
            type: .billboard,
            title: "At the Gym",
            subtitle: "Back around 5:30 PM. Please do not touch.",
            mediaUrl: nil,
            theme: "midnight_ember",
            dismissPolicy: .phoneOnly,
            targetDisplayId: "all",
            durationSeconds: nil
        )

        XCTAssertEqual(canvasDto.title, "At the Gym")
        XCTAssertEqual(canvasDto.subtitle, "Back around 5:30 PM. Please do not touch.")
        XCTAssertEqual(canvasDto.type, "billboard")
        XCTAssertEqual(canvasDto.dismiss_policy, "phone_only")
        XCTAssertTrue(wm.hasActiveMessages())

        let canvases = wm.getActiveCanvasesList()
        XCTAssertEqual(canvases.count, 1)
        XCTAssertEqual(canvases[0].title, "At the Gym")
        XCTAssertEqual(canvases[0].dismiss_policy, "phone_only")

        // Dismiss canvas
        wm.dismissCanvas(targetDisplayId: "all")
        XCTAssertFalse(wm.hasActiveMessages())
        XCTAssertEqual(wm.getActiveCanvasesList().count, 0)
    }

    func testCanvasPayloadEncodingAndDecoding() throws {
        let req = PostCanvasRequestPayload(
            type: "billboard",
            title: "Focus Time",
            subtitle: "Deep work session in progress",
            text: nil,
            media_url: nil,
            theme: "dark",
            dismiss_policy: "phone_only",
            target_display_id: "all",
            duration_seconds: 120
        )

        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PostCanvasRequestPayload.self, from: data)

        XCTAssertEqual(decoded.title, "Focus Time")
        XCTAssertEqual(decoded.subtitle, "Deep work session in progress")
        XCTAssertEqual(decoded.dismiss_policy, "phone_only")
        XCTAssertEqual(decoded.duration_seconds, 120)
    }

    func testImageAndVideoCanvasPayloads() throws {
        let wm = WindowManager.shared

        // 1. Image Canvas
        let imageCanvas = wm.showCanvas(
            type: .image,
            title: "Nature Wallpaper",
            subtitle: "Yosemite Valley",
            mediaUrl: "https://images.unsplash.com/photo-1426604966848-d7adac402bff",
            theme: "nature",
            dismissPolicy: .escAny,
            targetDisplayId: "all",
            durationSeconds: 60
        )
        XCTAssertEqual(imageCanvas.type, "image")
        XCTAssertEqual(imageCanvas.media_url, "https://images.unsplash.com/photo-1426604966848-d7adac402bff")

        // 2. Video Loop Canvas
        let videoCanvas = wm.showCanvas(
            type: .video,
            title: "Rainy Cafe",
            subtitle: "Lo-Fi Focus Stream",
            mediaUrl: "https://sample-videos.com/video321/mp4/720/big_buck_bunny_720p_1mb.mp4",
            theme: "rain",
            dismissPolicy: .phoneOnly,
            targetDisplayId: "all",
            durationSeconds: nil
        )
        XCTAssertEqual(videoCanvas.type, "video")
        XCTAssertEqual(videoCanvas.dismiss_policy, "phone_only")
        XCTAssertTrue(wm.hasActiveMessages())

        wm.dismissCanvas(targetDisplayId: "all")
        XCTAssertFalse(wm.hasActiveMessages())
    }
}


