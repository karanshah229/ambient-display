import Foundation
import SwiftUI
import AppKit
import WakeMeUpCore

@main
struct SnapshotApp {
    @MainActor
    static func renderSnapshot<V: View>(view: V, size: CGSize, outputPath: String) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2.0 // Crisp 2x Retina rendering
        renderer.proposedSize = ProposedViewSize(size)
        guard let nsImage = renderer.nsImage else {
            fatalError("Failed to render NSImage for \(outputPath)")
        }
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            fatalError("Failed to encode PNG for \(outputPath)")
        }
        do {
            try pngData.write(to: URL(fileURLWithPath: outputPath))
            print("Generated snapshot: \(outputPath)")
        } catch {
            fatalError("Failed to write to \(outputPath): \(error)")
        }
    }

    @MainActor
    static func main() {
        let outputDir = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "/Users/karan/projects/Personal_projects/wake-me-up/tests/artifacts"

        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let displaySize = CGSize(width: 1280, height: 720)

        let calendar = Calendar.current
        var dateComponents = DateComponents()
        dateComponents.year = 2026
        dateComponents.month = 10
        dateComponents.day = 3
        dateComponents.hour = 23
        dateComponents.minute = 15
        let bedtime = calendar.date(from: dateComponents) ?? Date()
        let targetWakeTime = bedtime.addingTimeInterval(7.5 * 3600) // 06:45 AM

        let session = SleepSession(
            bedtime: bedtime,
            targetWakeTime: targetWakeTime,
            reason: "auto_bedtime_detected"
        )

        // 1. Idle Standby Display
        let idleState = AppState(userDefaults: nil)
        idleState.setSimulatedState(state: .idle, session: nil, lastUpdated: bedtime.addingTimeInterval(-1800))
        renderSnapshot(
            view: AmbientDisplayView(appState: idleState, screenName: "Dell P2722H (Primary)"),
            size: displaySize,
            outputPath: "\(outputDir)/mac_flow_01_idle.png"
        )

        // 2. Night Ambient Countdown (Fell asleep 11:15 PM, 7h 30m remaining)
        let nightState = AppState(userDefaults: nil)
        nightState.setSimulatedState(state: .sleeping, session: session, lastUpdated: bedtime)
        renderSnapshot(
            view: AmbientDisplayView(appState: nightState, screenName: "Dell P2722H (Primary)"),
            size: displaySize,
            outputPath: "\(outputDir)/mac_flow_02_night_active.png"
        )

        // 3. Midnight Glance at 2:15 AM (Timer intact, 4h 30m remaining)
        dateComponents.hour = 2
        dateComponents.minute = 15
        dateComponents.day = 4
        let glanceTime = calendar.date(from: dateComponents) ?? bedtime.addingTimeInterval(3 * 3600)
        let glanceState = AppState(userDefaults: nil)
        glanceState.setSimulatedState(state: .sleeping, session: session, lastUpdated: glanceTime)
        renderSnapshot(
            view: AmbientDisplayView(appState: glanceState, screenName: "Dell P2722H (Primary)"),
            size: displaySize,
            outputPath: "\(outputDir)/mac_flow_03_glance_intact.png"
        )

        // 4. Final 5 Minutes Countdown (06:42 AM, ticking seconds mode)
        dateComponents.hour = 6
        dateComponents.minute = 42
        dateComponents.second = 12
        let countdownTime = calendar.date(from: dateComponents) ?? targetWakeTime.addingTimeInterval(-168)
        let countdownState = AppState(userDefaults: nil)
        countdownState.setSimulatedState(state: .sleeping, session: session, lastUpdated: countdownTime)
        renderSnapshot(
            view: AmbientDisplayView(appState: countdownState, screenName: "Dell P2722H (Primary)"),
            size: displaySize,
            outputPath: "\(outputDir)/mac_flow_04_countdown_seconds.png"
        )

        // 5. Morning WAKE ME UP Banner (06:45 AM, sunrise gold/emerald banner)
        dateComponents.hour = 6
        dateComponents.minute = 45
        dateComponents.second = 0
        let wakeTime = calendar.date(from: dateComponents) ?? targetWakeTime
        let wakeState = AppState(userDefaults: nil)
        wakeState.setSimulatedState(state: .wakeUpReady, session: session, lastUpdated: wakeTime)
        renderSnapshot(
            view: AmbientDisplayView(appState: wakeState, screenName: "Dell P2722H (Primary)"),
            size: displaySize,
            outputPath: "\(outputDir)/mac_flow_05_wakeup_banner.png"
        )

        print("All Mac ambient display snapshots successfully created!")
    }
}
