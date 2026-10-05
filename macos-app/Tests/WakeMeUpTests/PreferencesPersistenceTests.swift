import XCTest
@testable import WakeMeUpCore

final class PreferencesPersistenceTests: XCTestCase {

    var testSuiteName: String!
    var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testSuiteName = "test.wakemeup.preferences.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: testSuiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: testSuiteName)
        super.tearDown()
    }

    @MainActor
    func testPreferencesPersistAcrossSimulatedAppRestart() {
        // 1. First run / instance: User updates preferences
        let firstRun = AppState(userDefaults: testDefaults)
        firstRun.defaultSleepHours = 8.5
        firstRun.inactivityOffsetMinutes = 45.0
        firstRun.autoDetectInactivityOffset = false
        firstRun.sleepWindowStartHour = 22
        firstRun.sleepWindowEndHour = 7
        firstRun.autoPushWindowStartHour = 20
        firstRun.autoPushWindowEndHour = 22
        firstRun.ambientNightColorHex = "#112233"
        firstRun.ambientDawnColorHex = "#445566"
        firstRun.ambientWakeColorHex = "#778899"
        firstRun.showCountdownInMenuBar = false
        firstRun.isAwayMode = true
        firstRun.synchronize()

        // 2. Second run / instance simulating app close & reopening / update
        let secondRun = AppState(userDefaults: testDefaults)
        XCTAssertEqual(secondRun.defaultSleepHours, 8.5)
        XCTAssertEqual(secondRun.defaultSleepMinutes, 8.5 * 60.0)
        XCTAssertEqual(secondRun.inactivityOffsetMinutes, 45.0)
        XCTAssertFalse(secondRun.autoDetectInactivityOffset)
        XCTAssertEqual(secondRun.sleepWindowStartHour, 22)
        XCTAssertEqual(secondRun.sleepWindowEndHour, 7)
        XCTAssertEqual(secondRun.autoPushWindowStartHour, 20)
        XCTAssertEqual(secondRun.autoPushWindowEndHour, 22)
        XCTAssertEqual(secondRun.ambientNightColorHex, "#112233")
        XCTAssertEqual(secondRun.ambientDawnColorHex, "#445566")
        XCTAssertEqual(secondRun.ambientWakeColorHex, "#778899")
        XCTAssertFalse(secondRun.showCountdownInMenuBar)
        XCTAssertTrue(secondRun.isAwayMode)
    }

    @MainActor
    func testLaunchAtLoginPersistsAcrossSimulatedAppRestart() {
        // 1. User enables launch at login
        let manager1 = LaunchAtLoginManager(userDefaults: testDefaults)
        manager1.setEnabled(true)
        XCTAssertTrue(manager1.isEnabled)

        // 2. Simulated app restart / update
        let manager2 = LaunchAtLoginManager(userDefaults: testDefaults)
        XCTAssertTrue(manager2.isEnabled)

        // 3. User disables launch at login
        manager2.setEnabled(false)
        XCTAssertFalse(manager2.isEnabled)

        // 4. Simulated next restart
        let manager3 = LaunchAtLoginManager(userDefaults: testDefaults)
        XCTAssertFalse(manager3.isEnabled)
    }

    @MainActor
    func testIgnoredDisplaysPersistByNameAndUUID() {
        let firstRun = AppState(userDefaults: testDefaults)

        // Manually record an ignored display name and UUID (simulating an external monitor)
        let sampleMonitorName = "DELL P2722HE"
        let sampleMonitorUUID = "8B8D3282-B6DA-4B67-9D78-57BA1C25CFF7"

        firstRun.ignoredDisplayNames.insert(sampleMonitorName)
        firstRun.ignoredDisplayUUIDs.insert(sampleMonitorUUID)
        firstRun.ignoredDisplayIDs.insert(3)
        firstRun.synchronize()

        // Verify next run restores both collections
        let secondRun = AppState(userDefaults: testDefaults)
        XCTAssertTrue(secondRun.ignoredDisplayNames.contains(sampleMonitorName))
        XCTAssertTrue(secondRun.ignoredDisplayUUIDs.contains(sampleMonitorUUID))
        XCTAssertTrue(secondRun.ignoredDisplayIDs.contains(3))
    }

    @MainActor
    func testLegacyPreferencesMigration() {
        // Populate standard/legacy dictionary keys in a separate domain
        let legacyDefaults = UserDefaults(suiteName: "test.legacy.\(UUID().uuidString)")!
        legacyDefaults.set(9.0, forKey: "WakeMeUp_defaultSleepHours")
        legacyDefaults.set(true, forKey: "WakeMeUp_isAwayMode")
        legacyDefaults.set("#AA1122", forKey: "WakeMeUp_ambientNightColorHex")
        legacyDefaults.synchronize()

        // Create target AppState with empty testDefaults, but pointing migration logic to legacy
        testDefaults.set(legacyDefaults.double(forKey: "WakeMeUp_defaultSleepHours"), forKey: "WakeMeUp_defaultSleepHours")
        testDefaults.set(legacyDefaults.bool(forKey: "WakeMeUp_isAwayMode"), forKey: "WakeMeUp_isAwayMode")
        testDefaults.set(legacyDefaults.string(forKey: "WakeMeUp_ambientNightColorHex"), forKey: "WakeMeUp_ambientNightColorHex")
        testDefaults.synchronize()

        let appState = AppState(userDefaults: testDefaults)
        XCTAssertEqual(appState.defaultSleepHours, 9.0)
        XCTAssertTrue(appState.isAwayMode)
        XCTAssertEqual(appState.ambientNightColorHex, "#AA1122")

        legacyDefaults.removePersistentDomain(forName: legacyDefaults.description)
    }

    @MainActor
    func testDefaultAmbientThemeColors() {
        let freshState = AppState(userDefaults: testDefaults)
        XCTAssertEqual(freshState.ambientNightColorHex, "#D95926", "Default night color must be Midnight Ember")
        XCTAssertEqual(freshState.ambientDawnColorHex, "#FA7268", "Default dawn color must be Sunrise Coral")
        XCTAssertEqual(freshState.ambientWakeColorHex, "#FFD000", "Default wake color must be Radiant Solar Gold")

        // Test Reset to Defaults
        freshState.ambientNightColorHex = "#000000"
        freshState.ambientDawnColorHex = "#111111"
        freshState.ambientWakeColorHex = "#222222"
        freshState.resetAmbientDefaults()

        XCTAssertEqual(freshState.ambientNightColorHex, "#D95926")
        XCTAssertEqual(freshState.ambientDawnColorHex, "#FA7268")
        XCTAssertEqual(freshState.ambientWakeColorHex, "#FFD000")
    }

    @MainActor
    func testLegacyDawnAndWakeColorMigration() {
        // Given old legacy defaults with amber dawn (#FFBF66) and amber wake (#FFB800)
        testDefaults.set("#FFBF66", forKey: "WakeMeUp_ambientDawnColorHex")
        testDefaults.set("#FFB800", forKey: "WakeMeUp_ambientWakeColorHex")
        testDefaults.synchronize()

        // When launching AppState
        let appState = AppState(userDefaults: testDefaults)

        // Then it automatically upgrades them to the new natural sunrise defaults
        XCTAssertEqual(appState.ambientDawnColorHex, "#FA7268")
        XCTAssertEqual(appState.ambientWakeColorHex, "#FFD000")
    }
}
