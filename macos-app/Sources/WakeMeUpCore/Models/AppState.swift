import Foundation
import Combine
import CoreGraphics
import AppKit

public enum SessionState: String, Codable {
    case idle
    case sleeping
    case wakeUpReady
}

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    public nonisolated static let defaultsSuiteName = "com.wakemeup.mac"

    public nonisolated static var defaultUserDefaults: UserDefaults {
        if let suite = UserDefaults(suiteName: defaultsSuiteName) {
            return suite
        }
        return UserDefaults.standard
    }

    @Published public private(set) var state: SessionState = .idle
    @Published public private(set) var currentSession: SleepSession? = nil
    @Published public var isAwayMode: Bool = false {
        didSet {
            savePreference(isAwayMode, forKey: "WakeMeUp_isAwayMode")
            handleAwayModeChanged()
        }
    }
    @Published public var defaultSleepHours: Double = 7.5 {
        didSet {
            savePreference(defaultSleepHours, forKey: "WakeMeUp_defaultSleepHours")
        }
    }
    public var defaultSleepMinutes: Double {
        defaultSleepHours * 60.0
    }
    @Published public var inactivityOffsetMinutes: Double = 30.0 {
        didSet {
            savePreference(inactivityOffsetMinutes, forKey: "WakeMeUp_inactivityOffsetMinutes")
        }
    }
    @Published public var autoDetectInactivityOffset: Bool = true {
        didSet {
            savePreference(autoDetectInactivityOffset, forKey: "WakeMeUp_autoDetectInactivityOffset")
        }
    }
    @Published public var sleepWindowStartHour: Int = 21 { // 9 PM
        didSet {
            savePreference(sleepWindowStartHour, forKey: "WakeMeUp_sleepWindowStartHour")
        }
    }
    @Published public var sleepWindowEndHour: Int = 6 { // 6 AM
        didSet {
            savePreference(sleepWindowEndHour, forKey: "WakeMeUp_sleepWindowEndHour")
        }
    }
    @Published public var autoPushWindowStartHour: Int = 21 { // 9 PM
        didSet {
            savePreference(autoPushWindowStartHour, forKey: "WakeMeUp_autoPushWindowStartHour")
        }
    }
    @Published public var autoPushWindowEndHour: Int = 23 { // 11 PM
        didSet {
            savePreference(autoPushWindowEndHour, forKey: "WakeMeUp_autoPushWindowEndHour")
        }
    }
    @Published public var ignoredDisplayIDs: Set<CGDirectDisplayID> = [] {
        didSet {
            let array = Array(ignoredDisplayIDs).map { Int($0) }
            savePreference(array, forKey: "WakeMeUp_ignoredDisplayIDs")
        }
    }
    @Published public var ignoredDisplayNames: Set<String> = [] {
        didSet {
            savePreference(Array(ignoredDisplayNames), forKey: "WakeMeUp_ignoredDisplayNames")
        }
    }
    @Published public var ignoredDisplayUUIDs: Set<String> = [] {
        didSet {
            savePreference(Array(ignoredDisplayUUIDs), forKey: "WakeMeUp_ignoredDisplayUUIDs")
        }
    }
    @Published public var ambientNightColorHex: String = "#D95926" {
        didSet {
            savePreference(ambientNightColorHex, forKey: "WakeMeUp_ambientNightColorHex")
        }
    }
    @Published public var ambientDawnColorHex: String = "#FA7268" {
        didSet {
            savePreference(ambientDawnColorHex, forKey: "WakeMeUp_ambientDawnColorHex")
        }
    }
    @Published public var ambientWakeColorHex: String = "#FFD000" {
        didSet {
            savePreference(ambientWakeColorHex, forKey: "WakeMeUp_ambientWakeColorHex")
        }
    }
    @Published public var showCountdownInMenuBar: Bool = true {
        didSet {
            savePreference(showCountdownInMenuBar, forKey: "WakeMeUp_showCountdownInMenuBar")
        }
    }
    @Published public private(set) var isTestMode: Bool = false
    @Published public private(set) var lastUpdated: Date = Date()

    private var timer: Timer?
    private let userDefaults: UserDefaults?

    public init(userDefaults: UserDefaults? = defaultUserDefaults) {
        self.userDefaults = userDefaults
        migratePreferencesIfNeeded()

        self.isAwayMode = userDefaults?.bool(forKey: "WakeMeUp_isAwayMode") ?? false

        let savedHours = userDefaults?.double(forKey: "WakeMeUp_defaultSleepHours") ?? 0
        if savedHours > 0 {
            self.defaultSleepHours = savedHours
        } else {
            let legacyMins = userDefaults?.double(forKey: "WakeMeUp_defaultSleepMinutes") ?? 0
            self.defaultSleepHours = legacyMins > 0 ? (legacyMins / 60.0) : 7.5
        }

        let savedOffset = userDefaults?.double(forKey: "WakeMeUp_inactivityOffsetMinutes") ?? 0
        self.inactivityOffsetMinutes = savedOffset > 0 ? savedOffset : 30.0
        self.autoDetectInactivityOffset = userDefaults?.object(forKey: "WakeMeUp_autoDetectInactivityOffset") as? Bool ?? true

        let savedSleepStart = userDefaults?.object(forKey: "WakeMeUp_sleepWindowStartHour") as? Int
        self.sleepWindowStartHour = savedSleepStart ?? 21
        let savedSleepEnd = userDefaults?.object(forKey: "WakeMeUp_sleepWindowEndHour") as? Int
        self.sleepWindowEndHour = savedSleepEnd ?? 6

        let savedAutoPushStart = userDefaults?.object(forKey: "WakeMeUp_autoPushWindowStartHour") as? Int
        self.autoPushWindowStartHour = savedAutoPushStart ?? 21
        let savedAutoPushEnd = userDefaults?.object(forKey: "WakeMeUp_autoPushWindowEndHour") as? Int
        self.autoPushWindowEndHour = savedAutoPushEnd ?? 23

        if let savedIgnored = userDefaults?.array(forKey: "WakeMeUp_ignoredDisplayIDs") as? [Int] {
            self.ignoredDisplayIDs = Set(savedIgnored.map { CGDirectDisplayID($0) })
        } else {
            self.ignoredDisplayIDs = []
        }

        if let savedNames = userDefaults?.array(forKey: "WakeMeUp_ignoredDisplayNames") as? [String] {
            self.ignoredDisplayNames = Set(savedNames)
        } else {
            self.ignoredDisplayNames = []
        }

        if let savedUUIDs = userDefaults?.array(forKey: "WakeMeUp_ignoredDisplayUUIDs") as? [String] {
            self.ignoredDisplayUUIDs = Set(savedUUIDs)
        } else {
            self.ignoredDisplayUUIDs = []
        }

        // Re-sync ignoredDisplayIDs with currently connected screens matching ignored UUIDs or names
        for screen in NSScreen.screens {
            let screenId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let screenName = screen.localizedName
            let uuid = persistentUUID(for: screenId)
            if ignoredDisplayNames.contains(screenName) || (uuid != nil && ignoredDisplayUUIDs.contains(uuid!)) {
                self.ignoredDisplayIDs.insert(screenId)
            }
        }

        self.ambientNightColorHex = userDefaults?.string(forKey: "WakeMeUp_ambientNightColorHex") ?? "#D95926"
        let savedDawn = userDefaults?.string(forKey: "WakeMeUp_ambientDawnColorHex")
        self.ambientDawnColorHex = (savedDawn == nil || savedDawn == "#FFBF66") ? "#FA7268" : savedDawn!
        let savedWake = userDefaults?.string(forKey: "WakeMeUp_ambientWakeColorHex")
        self.ambientWakeColorHex = (savedWake == nil || savedWake == "#40E68C" || savedWake == "#FFB800") ? "#FFD000" : savedWake!
        self.showCountdownInMenuBar = userDefaults?.object(forKey: "WakeMeUp_showCountdownInMenuBar") as? Bool ?? true
    }

    private func migratePreferencesIfNeeded() {
        guard let target = userDefaults else { return }
        let sources = [UserDefaults.standard, UserDefaults(suiteName: "WakeMeUp")].compactMap { $0 }
        let keys = [
            "WakeMeUp_isAwayMode",
            "WakeMeUp_defaultSleepHours",
            "WakeMeUp_defaultSleepMinutes",
            "WakeMeUp_inactivityOffsetMinutes",
            "WakeMeUp_autoDetectInactivityOffset",
            "WakeMeUp_sleepWindowStartHour",
            "WakeMeUp_sleepWindowEndHour",
            "WakeMeUp_autoPushWindowStartHour",
            "WakeMeUp_autoPushWindowEndHour",
            "WakeMeUp_ignoredDisplayIDs",
            "WakeMeUp_ignoredDisplayNames",
            "WakeMeUp_ignoredDisplayUUIDs",
            "WakeMeUp_ambientNightColorHex",
            "WakeMeUp_ambientDawnColorHex",
            "WakeMeUp_ambientWakeColorHex",
            "WakeMeUp_showCountdownInMenuBar",
            "WakeMeUp_launchAtLogin"
        ]
        for key in keys {
            if target.object(forKey: key) == nil {
                for source in sources {
                    if let val = source.object(forKey: key) {
                        target.set(val, forKey: key)
                        break
                    }
                }
            }
        }
        target.synchronize()
    }

    public func persistentUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cfUUID) as String
    }

    public func isDisplayIgnored(screen: NSScreen) -> Bool {
        let screenId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let screenName = screen.localizedName
        let uuid = persistentUUID(for: screenId)

        if ignoredDisplayIDs.contains(screenId) { return true }
        if ignoredDisplayNames.contains(screenName) { return true }
        if let uuid = uuid, ignoredDisplayUUIDs.contains(uuid) { return true }
        return false
    }

    public func toggleDisplayIgnored(screen: NSScreen) {
        let screenId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let screenName = screen.localizedName
        let uuid = persistentUUID(for: screenId)

        let currentlyIgnored = isDisplayIgnored(screen: screen)
        if currentlyIgnored {
            ignoredDisplayIDs.remove(screenId)
            ignoredDisplayNames.remove(screenName)
            if let uuid = uuid { ignoredDisplayUUIDs.remove(uuid) }
        } else {
            ignoredDisplayIDs.insert(screenId)
            ignoredDisplayNames.insert(screenName)
            if let uuid = uuid { ignoredDisplayUUIDs.insert(uuid) }
        }
    }

    public func toggleDisplayIgnored(id: CGDirectDisplayID) {
        if let matchingScreen = NSScreen.screens.first(where: {
            (( $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) == id
        }) {
            toggleDisplayIgnored(screen: matchingScreen)
        } else {
            if ignoredDisplayIDs.contains(id) {
                ignoredDisplayIDs.remove(id)
            } else {
                ignoredDisplayIDs.insert(id)
            }
        }
    }

    public func resetAmbientDefaults() {
        ambientNightColorHex = "#D95926"
        ambientDawnColorHex = "#FA7268"
        ambientWakeColorHex = "#FFD000"
    }

    private func savePreference(_ value: Any?, forKey key: String) {
        userDefaults?.set(value, forKey: key)
        userDefaults?.synchronize()
        if userDefaults != UserDefaults.standard {
            UserDefaults.standard.set(value, forKey: key)
            UserDefaults.standard.synchronize()
        }
    }

    public func synchronize() {
        userDefaults?.synchronize()
        UserDefaults.standard.synchronize()
    }

    public func startSleep(
        bedtime: Date = Date(),
        durationMinutes: Double = 450.0,
        reason: String = "auto"
    ) {
        guard !isAwayMode else {
            print("[AppState] Sleep event ignored because Away Mode is active.")
            return
        }

        let session = SleepSession(
            bedtime: bedtime,
            durationMinutes: durationMinutes,
            reason: reason
        )
        self.currentSession = session
        self.isTestMode = false
        self.state = session.isExpired() ? .wakeUpReady : .sleeping
        self.lastUpdated = Date()

        startTickTimer()
        print("[AppState] Started sleep session: Bedtime = \(session.formattedBedtime), Target = \(session.formattedTargetTime) (\(durationMinutes) mins)")
    }

    public func startTestMode(durationSeconds: Int = 10) {
        let now = Date()
        let target = now.addingTimeInterval(Double(durationSeconds))
        let session = SleepSession(
            bedtime: now.addingTimeInterval(-450 * 60), // pretend fell asleep 7.5h ago
            targetWakeTime: target,
            reason: "test"
        )
        self.currentSession = session
        self.isTestMode = true
        self.state = .sleeping
        self.lastUpdated = Date()

        startTickTimer()
        print("[AppState] Started Test Mode with \(durationSeconds)s duration.")
    }

    public func triggerWakeUpReady() {
        self.state = .wakeUpReady
        self.lastUpdated = Date()
        print("[AppState] Target time reached -> State is now wakeUpReady!")
    }

    public func dismissWakeUp() {
        stopSleep()
    }

    public func stopSleep() {
        self.state = .idle
        self.currentSession = nil
        self.isTestMode = false
        self.lastUpdated = Date()
        stopTickTimer()
        print("[AppState] Sleep session stopped/idle.")
    }

    public func toggleAwayMode() {
        self.isAwayMode.toggle()
    }

    public func setSimulatedState(
        state: SessionState,
        session: SleepSession?,
        lastUpdated: Date = Date(),
        isTestMode: Bool = false
    ) {
        self.state = state
        self.currentSession = session
        self.lastUpdated = lastUpdated
        self.isTestMode = isTestMode
    }

    private func handleAwayModeChanged() {
        if isAwayMode && state != .idle {
            stopSleep()
        }
        print("[AppState] Away Mode is now: \(isAwayMode)")
    }

    private func startTickTimer() {
        timer?.invalidate()
        // Fast timer (1 second) to handle state changes, 5-minute countdowns, and tests accurately
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func stopTickTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let session = currentSession, state == .sleeping else { return }
        self.lastUpdated = Date()

        if session.isExpired() {
            triggerWakeUpReady()
        }
    }
}
