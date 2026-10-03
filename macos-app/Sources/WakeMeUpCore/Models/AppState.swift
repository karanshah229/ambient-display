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

    @Published public private(set) var state: SessionState = .idle
    @Published public private(set) var currentSession: SleepSession? = nil
    @Published public var isAwayMode: Bool = false {
        didSet {
            saveAwayMode(isAwayMode)
            handleAwayModeChanged()
        }
    }
    @Published public var defaultSleepHours: Double = 7.5 {
        didSet {
            userDefaults?.set(defaultSleepHours, forKey: "WakeMeUp_defaultSleepHours")
        }
    }
    public var defaultSleepMinutes: Double {
        defaultSleepHours * 60.0
    }
    @Published public var inactivityOffsetMinutes: Double = 30.0 {
        didSet {
            userDefaults?.set(inactivityOffsetMinutes, forKey: "WakeMeUp_inactivityOffsetMinutes")
        }
    }
    @Published public var autoDetectInactivityOffset: Bool = true {
        didSet {
            userDefaults?.set(autoDetectInactivityOffset, forKey: "WakeMeUp_autoDetectInactivityOffset")
        }
    }
    @Published public var sleepWindowStartHour: Int = 21 { // 9 PM
        didSet {
            userDefaults?.set(sleepWindowStartHour, forKey: "WakeMeUp_sleepWindowStartHour")
        }
    }
    @Published public var sleepWindowEndHour: Int = 6 { // 6 AM
        didSet {
            userDefaults?.set(sleepWindowEndHour, forKey: "WakeMeUp_sleepWindowEndHour")
        }
    }
    @Published public var autoPushWindowStartHour: Int = 21 { // 9 PM
        didSet {
            userDefaults?.set(autoPushWindowStartHour, forKey: "WakeMeUp_autoPushWindowStartHour")
        }
    }
    @Published public var autoPushWindowEndHour: Int = 23 { // 11 PM
        didSet {
            userDefaults?.set(autoPushWindowEndHour, forKey: "WakeMeUp_autoPushWindowEndHour")
        }
    }
    @Published public var ignoredDisplayIDs: Set<CGDirectDisplayID> = [] {
        didSet {
            let array = Array(ignoredDisplayIDs).map { Int($0) }
            userDefaults?.set(array, forKey: "WakeMeUp_ignoredDisplayIDs")
        }
    }
    @Published public var ambientNightColorHex: String = "#D95926" {
        didSet {
            userDefaults?.set(ambientNightColorHex, forKey: "WakeMeUp_ambientNightColorHex")
        }
    }
    @Published public var ambientDawnColorHex: String = "#FFBF66" {
        didSet {
            userDefaults?.set(ambientDawnColorHex, forKey: "WakeMeUp_ambientDawnColorHex")
        }
    }
    @Published public var ambientWakeColorHex: String = "#40E68C" {
        didSet {
            userDefaults?.set(ambientWakeColorHex, forKey: "WakeMeUp_ambientWakeColorHex")
        }
    }
    @Published public var showCountdownInMenuBar: Bool = true {
        didSet {
            userDefaults?.set(showCountdownInMenuBar, forKey: "WakeMeUp_showCountdownInMenuBar")
        }
    }
    @Published public private(set) var isTestMode: Bool = false
    @Published public private(set) var lastUpdated: Date = Date()

    private var timer: Timer?
    private let userDefaults: UserDefaults?

    public init(userDefaults: UserDefaults? = UserDefaults.standard) {
        self.userDefaults = userDefaults
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

        self.ambientNightColorHex = userDefaults?.string(forKey: "WakeMeUp_ambientNightColorHex") ?? "#D95926"
        self.ambientDawnColorHex = userDefaults?.string(forKey: "WakeMeUp_ambientDawnColorHex") ?? "#FFBF66"
        self.ambientWakeColorHex = userDefaults?.string(forKey: "WakeMeUp_ambientWakeColorHex") ?? "#40E68C"
        self.showCountdownInMenuBar = userDefaults?.object(forKey: "WakeMeUp_showCountdownInMenuBar") as? Bool ?? true
    }

    public func toggleDisplayIgnored(id: CGDirectDisplayID) {
        if ignoredDisplayIDs.contains(id) {
            ignoredDisplayIDs.remove(id)
        } else {
            ignoredDisplayIDs.insert(id)
        }
    }

    public func resetAmbientDefaults() {
        ambientNightColorHex = "#D95926"
        ambientDawnColorHex = "#FFBF66"
        ambientWakeColorHex = "#40E68C"
    }

    private func saveAwayMode(_ value: Bool) {
        userDefaults?.set(value, forKey: "WakeMeUp_isAwayMode")
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
