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

    public nonisolated static let defaultsSuiteName = "com.ambientdisplay.mac"

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
            savePreference(isAwayMode, forKey: "AmbientDisplay_isAwayMode")
            handleAwayModeChanged()
        }
    }
    @Published public var defaultSleepHours: Double = 7.5 {
        didSet {
            savePreference(defaultSleepHours, forKey: "AmbientDisplay_defaultSleepHours")
        }
    }
    public var defaultSleepMinutes: Double {
        defaultSleepHours * 60.0
    }
    @Published public var inactivityOffsetMinutes: Double = 30.0 {
        didSet {
            savePreference(inactivityOffsetMinutes, forKey: "AmbientDisplay_inactivityOffsetMinutes")
        }
    }
    @Published public var autoDetectInactivityOffset: Bool = true {
        didSet {
            savePreference(autoDetectInactivityOffset, forKey: "AmbientDisplay_autoDetectInactivityOffset")
        }
    }
    @Published public var sleepWindowStartHour: Int = 21 { // 9 PM
        didSet {
            savePreference(sleepWindowStartHour, forKey: "AmbientDisplay_sleepWindowStartHour")
        }
    }
    @Published public var sleepWindowEndHour: Int = 6 { // 6 AM
        didSet {
            savePreference(sleepWindowEndHour, forKey: "AmbientDisplay_sleepWindowEndHour")
        }
    }
    @Published public var autoPushWindowStartHour: Int = 21 { // 9 PM
        didSet {
            savePreference(autoPushWindowStartHour, forKey: "AmbientDisplay_autoPushWindowStartHour")
        }
    }
    @Published public var autoPushWindowEndHour: Int = 23 { // 11 PM
        didSet {
            savePreference(autoPushWindowEndHour, forKey: "AmbientDisplay_autoPushWindowEndHour")
        }
    }
    @Published public var ignoredDisplayIDs: Set<CGDirectDisplayID> = [] {
        didSet {
            let array = Array(ignoredDisplayIDs).map { Int($0) }
            savePreference(array, forKey: "AmbientDisplay_ignoredDisplayIDs")
        }
    }
    @Published public var ignoredDisplayNames: Set<String> = [] {
        didSet {
            savePreference(Array(ignoredDisplayNames), forKey: "AmbientDisplay_ignoredDisplayNames")
        }
    }
    @Published public var ignoredDisplayUUIDs: Set<String> = [] {
        didSet {
            savePreference(Array(ignoredDisplayUUIDs), forKey: "AmbientDisplay_ignoredDisplayUUIDs")
        }
    }
    @Published public var ambientNightColorHex: String = "#D95926" {
        didSet {
            savePreference(ambientNightColorHex, forKey: "AmbientDisplay_ambientNightColorHex")
        }
    }
    @Published public var ambientDawnColorHex: String = "#FA7268" {
        didSet {
            savePreference(ambientDawnColorHex, forKey: "AmbientDisplay_ambientDawnColorHex")
        }
    }
    @Published public var ambientWakeColorHex: String = "#FFD000" {
        didSet {
            savePreference(ambientWakeColorHex, forKey: "AmbientDisplay_ambientWakeColorHex")
        }
    }
    @Published public var showCountdownInMenuBar: Bool = true {
        didSet {
            savePreference(showCountdownInMenuBar, forKey: "AmbientDisplay_showCountdownInMenuBar")
        }
    }
    @Published public private(set) var isTestMode: Bool = false
    @Published public private(set) var lastUpdated: Date = Date()

    private var timer: Timer?
    private let userDefaults: UserDefaults?

    public init(userDefaults: UserDefaults? = defaultUserDefaults) {
        self.userDefaults = userDefaults
        migratePreferencesIfNeeded()

        self.isAwayMode = userDefaults?.bool(forKey: "AmbientDisplay_isAwayMode") ?? (userDefaults?.bool(forKey: "AmbientDisplay_isAwayMode") ?? false)

        let savedHours = userDefaults?.double(forKey: "AmbientDisplay_defaultSleepHours") ?? (userDefaults?.double(forKey: "AmbientDisplay_defaultSleepHours") ?? 0)
        if savedHours > 0 {
            self.defaultSleepHours = savedHours
        } else {
            let legacyMins = userDefaults?.double(forKey: "AmbientDisplay_defaultSleepMinutes") ?? (userDefaults?.double(forKey: "AmbientDisplay_defaultSleepMinutes") ?? 0)
            self.defaultSleepHours = legacyMins > 0 ? (legacyMins / 60.0) : 7.5
        }

        let savedOffset = userDefaults?.double(forKey: "AmbientDisplay_inactivityOffsetMinutes") ?? (userDefaults?.double(forKey: "AmbientDisplay_inactivityOffsetMinutes") ?? 0)
        self.inactivityOffsetMinutes = savedOffset > 0 ? savedOffset : 30.0
        self.autoDetectInactivityOffset = (userDefaults?.object(forKey: "AmbientDisplay_autoDetectInactivityOffset") as? Bool) ?? (userDefaults?.object(forKey: "AmbientDisplay_autoDetectInactivityOffset") as? Bool ?? true)

        let savedSleepStart = (userDefaults?.object(forKey: "AmbientDisplay_sleepWindowStartHour") as? Int) ?? (userDefaults?.object(forKey: "AmbientDisplay_sleepWindowStartHour") as? Int)
        self.sleepWindowStartHour = savedSleepStart ?? 21
        let savedSleepEnd = (userDefaults?.object(forKey: "AmbientDisplay_sleepWindowEndHour") as? Int) ?? (userDefaults?.object(forKey: "AmbientDisplay_sleepWindowEndHour") as? Int)
        self.sleepWindowEndHour = savedSleepEnd ?? 6

        let savedAutoPushStart = (userDefaults?.object(forKey: "AmbientDisplay_autoPushWindowStartHour") as? Int) ?? (userDefaults?.object(forKey: "AmbientDisplay_autoPushWindowStartHour") as? Int)
        self.autoPushWindowStartHour = savedAutoPushStart ?? 21
        let savedAutoPushEnd = (userDefaults?.object(forKey: "AmbientDisplay_autoPushWindowEndHour") as? Int) ?? (userDefaults?.object(forKey: "AmbientDisplay_autoPushWindowEndHour") as? Int)
        self.autoPushWindowEndHour = savedAutoPushEnd ?? 23

        if let savedIgnored = (userDefaults?.array(forKey: "AmbientDisplay_ignoredDisplayIDs") as? [Int]) ?? (userDefaults?.array(forKey: "AmbientDisplay_ignoredDisplayIDs") as? [Int]) {
            self.ignoredDisplayIDs = Set(savedIgnored.map { CGDirectDisplayID($0) })
        } else {
            self.ignoredDisplayIDs = []
        }

        if let savedNames = (userDefaults?.array(forKey: "AmbientDisplay_ignoredDisplayNames") as? [String]) ?? (userDefaults?.array(forKey: "AmbientDisplay_ignoredDisplayNames") as? [String]) {
            self.ignoredDisplayNames = Set(savedNames)
        } else {
            self.ignoredDisplayNames = []
        }

        if let savedUUIDs = (userDefaults?.array(forKey: "AmbientDisplay_ignoredDisplayUUIDs") as? [String]) ?? (userDefaults?.array(forKey: "AmbientDisplay_ignoredDisplayUUIDs") as? [String]) {
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

        self.ambientNightColorHex = userDefaults?.string(forKey: "AmbientDisplay_ambientNightColorHex") ?? (userDefaults?.string(forKey: "AmbientDisplay_ambientNightColorHex") ?? "#D95926")
        let savedDawn = userDefaults?.string(forKey: "AmbientDisplay_ambientDawnColorHex") ?? userDefaults?.string(forKey: "AmbientDisplay_ambientDawnColorHex")
        self.ambientDawnColorHex = (savedDawn == nil || savedDawn == "#FFBF66") ? "#FA7268" : savedDawn!
        let savedWake = userDefaults?.string(forKey: "AmbientDisplay_ambientWakeColorHex") ?? userDefaults?.string(forKey: "AmbientDisplay_ambientWakeColorHex")
        self.ambientWakeColorHex = (savedWake == nil || savedWake == "#40E68C" || savedWake == "#FFB800") ? "#FFD000" : savedWake!
        self.showCountdownInMenuBar = (userDefaults?.object(forKey: "AmbientDisplay_showCountdownInMenuBar") as? Bool) ?? (userDefaults?.object(forKey: "AmbientDisplay_showCountdownInMenuBar") as? Bool ?? true)
    }

    private func migratePreferencesIfNeeded() {
        guard let target = userDefaults else { return }
        let sources = [UserDefaults.standard, UserDefaults(suiteName: "AmbientDisplay")].compactMap { $0 }
        let legacyPairs: [(String, String)] = [
            ("AmbientDisplay_isAwayMode", "AmbientDisplay_isAwayMode"),
            ("AmbientDisplay_defaultSleepHours", "AmbientDisplay_defaultSleepHours"),
            ("AmbientDisplay_defaultSleepMinutes", "AmbientDisplay_defaultSleepMinutes"),
            ("AmbientDisplay_inactivityOffsetMinutes", "AmbientDisplay_inactivityOffsetMinutes"),
            ("AmbientDisplay_autoDetectInactivityOffset", "AmbientDisplay_autoDetectInactivityOffset"),
            ("AmbientDisplay_sleepWindowStartHour", "AmbientDisplay_sleepWindowStartHour"),
            ("AmbientDisplay_sleepWindowEndHour", "AmbientDisplay_sleepWindowEndHour"),
            ("AmbientDisplay_autoPushWindowStartHour", "AmbientDisplay_autoPushWindowStartHour"),
            ("AmbientDisplay_autoPushWindowEndHour", "AmbientDisplay_autoPushWindowEndHour"),
            ("AmbientDisplay_ignoredDisplayIDs", "AmbientDisplay_ignoredDisplayIDs"),
            ("AmbientDisplay_ignoredDisplayNames", "AmbientDisplay_ignoredDisplayNames"),
            ("AmbientDisplay_ignoredDisplayUUIDs", "AmbientDisplay_ignoredDisplayUUIDs"),
            ("AmbientDisplay_ambientNightColorHex", "AmbientDisplay_ambientNightColorHex"),
            ("AmbientDisplay_ambientDawnColorHex", "AmbientDisplay_ambientDawnColorHex"),
            ("AmbientDisplay_ambientWakeColorHex", "AmbientDisplay_ambientWakeColorHex"),
            ("AmbientDisplay_showCountdownInMenuBar", "AmbientDisplay_showCountdownInMenuBar"),
            ("AmbientDisplay_launchAtLogin", "AmbientDisplay_launchAtLogin")
        ]
        for (oldKey, newKey) in legacyPairs {
            if target.object(forKey: newKey) == nil {
                if let val = target.object(forKey: oldKey) {
                    target.set(val, forKey: newKey)
                } else {
                    for source in sources {
                        if let val = source.object(forKey: newKey) ?? source.object(forKey: oldKey) {
                            target.set(val, forKey: newKey)
                            break
                        }
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

    private var isApplyingCloudPreferences: Bool = false

    public func applyCloudPreferences(_ prefs: [String: Any]) {
        isApplyingCloudPreferences = true
        defer { isApplyingCloudPreferences = false }

        if let away = prefs["isAwayMode"] as? Bool, away != self.isAwayMode {
            self.isAwayMode = away
        }
        if let hours = (prefs["defaultSleepHours"] as? NSNumber)?.doubleValue, hours > 0, hours != self.defaultSleepHours {
            self.defaultSleepHours = hours
        }
        if let start = (prefs["sleepWindowStartHour"] as? NSNumber)?.intValue, start != self.sleepWindowStartHour {
            self.sleepWindowStartHour = start
        }
        if let end = (prefs["sleepWindowEndHour"] as? NSNumber)?.intValue, end != self.sleepWindowEndHour {
            self.sleepWindowEndHour = end
        }
        if let pushStart = (prefs["autoPushWindowStartHour"] as? NSNumber)?.intValue, pushStart != self.autoPushWindowStartHour {
            self.autoPushWindowStartHour = pushStart
        }
        if let pushEnd = (prefs["autoPushWindowEndHour"] as? NSNumber)?.intValue, pushEnd != self.autoPushWindowEndHour {
            self.autoPushWindowEndHour = pushEnd
        }
        if let offset = (prefs["inactivityOffsetMinutes"] as? NSNumber)?.doubleValue, offset > 0, offset != self.inactivityOffsetMinutes {
            self.inactivityOffsetMinutes = offset
        }
        if let autoDetect = prefs["autoDetectInactivity"] as? Bool, autoDetect != self.autoDetectInactivityOffset {
            self.autoDetectInactivityOffset = autoDetect
        }
        if let night = prefs["ambientNightColorHex"] as? String, night != self.ambientNightColorHex {
            self.ambientNightColorHex = night
        }
        if let dawn = prefs["ambientDawnColorHex"] as? String, dawn != self.ambientDawnColorHex {
            self.ambientDawnColorHex = dawn
        }
        if let wake = prefs["ambientWakeColorHex"] as? String, wake != self.ambientWakeColorHex {
            self.ambientWakeColorHex = wake
        }
    }

    public func pushCloudPreferences() {
        guard userDefaults == AppState.defaultUserDefaults else { return }
        guard !isApplyingCloudPreferences else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.userDefaults == AppState.defaultUserDefaults else { return }
            guard !self.isApplyingCloudPreferences else { return }
            guard FirebaseCloudService.shared.currentUser != nil else { return }

            let prefs: [String: Any] = [
                "isAwayMode": self.isAwayMode,
                "defaultSleepHours": self.defaultSleepHours,
                "sleepWindowStartHour": self.sleepWindowStartHour,
                "sleepWindowEndHour": self.sleepWindowEndHour,
                "autoPushWindowStartHour": self.autoPushWindowStartHour,
                "autoPushWindowEndHour": self.autoPushWindowEndHour,
                "inactivityOffsetMinutes": self.inactivityOffsetMinutes,
                "autoDetectInactivity": self.autoDetectInactivityOffset,
                "ambientNightColorHex": self.ambientNightColorHex,
                "ambientDawnColorHex": self.ambientDawnColorHex,
                "ambientWakeColorHex": self.ambientWakeColorHex
            ]
            FirebaseCloudService.shared.pushPreferences(prefs)
        }
    }

    private func savePreference(_ value: Any?, forKey key: String) {
        userDefaults?.set(value, forKey: key)
        userDefaults?.synchronize()
        if userDefaults != UserDefaults.standard {
            UserDefaults.standard.set(value, forKey: key)
            UserDefaults.standard.synchronize()
        }
        if !isApplyingCloudPreferences {
            pushCloudPreferences()
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
