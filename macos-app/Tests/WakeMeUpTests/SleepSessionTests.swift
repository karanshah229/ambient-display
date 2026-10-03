import XCTest
@testable import WakeMeUpCore

final class SleepSessionTests: XCTestCase {

    func testSleepSessionCalculates7Point5HoursCorrectly() {
        let bedtime = Date(timeIntervalSince1970: 1000000)
        let session = SleepSession(bedtime: bedtime, durationMinutes: 450.0)

        let expectedWakeTime = bedtime.addingTimeInterval(450.0 * 60.0) // 27000 seconds
        XCTAssertEqual(session.targetWakeTime, expectedWakeTime)
        XCTAssertEqual(session.durationMinutes, 450.0)
    }

    func testCountdownFormattingOverFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1000000)
        let target = now.addingTimeInterval(3600) // 1 hour remaining
        let session = SleepSession(bedtime: now.addingTimeInterval(-3600), targetWakeTime: target)

        let countdown = session.formattedCountdown(at: now)
        XCTAssertEqual(countdown, "1h 0m remaining")
    }

    func testCountdownFormattingFinalFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1000000)
        let target = now.addingTimeInterval(245) // 4 minutes, 5 seconds remaining
        let session = SleepSession(bedtime: now.addingTimeInterval(-10000), targetWakeTime: target)

        XCTAssertTrue(session.isFinalFiveMinutes(at: now))
        let countdown = session.formattedCountdown(at: now)
        XCTAssertEqual(countdown, "04:05")
    }

    func testCountdownFormattingExpired() {
        let now = Date(timeIntervalSince1970: 1000000)
        let target = now.addingTimeInterval(-10) // 10 seconds past wake time
        let session = SleepSession(bedtime: now.addingTimeInterval(-10000), targetWakeTime: target)

        XCTAssertTrue(session.isExpired(at: now))
        let countdown = session.formattedCountdown(at: now)
        XCTAssertEqual(countdown, "00:00")
    }

    @MainActor
    func testAppStateTransitions() {
        let appState = AppState(userDefaults: nil)
        XCTAssertEqual(appState.state, .idle)

        let bedtime = Date()
        appState.startSleep(bedtime: bedtime, durationMinutes: 450.0)
        XCTAssertEqual(appState.state, .sleeping)
        XCTAssertNotNil(appState.currentSession)

        appState.triggerWakeUpReady()
        XCTAssertEqual(appState.state, .wakeUpReady)

        appState.stopSleep()
        XCTAssertEqual(appState.state, .idle)
        XCTAssertNil(appState.currentSession)
    }

    @MainActor
    func testAwayModeIgnoresSleepEvents() {
        let appState = AppState(userDefaults: nil)
        appState.isAwayMode = true

        appState.startSleep(bedtime: Date(), durationMinutes: 450.0)
        XCTAssertEqual(appState.state, .idle)
        XCTAssertNil(appState.currentSession)
    }
}
