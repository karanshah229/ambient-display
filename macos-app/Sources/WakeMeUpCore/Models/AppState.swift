import Foundation
import Combine

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
    @Published public private(set) var isTestMode: Bool = false
    @Published public private(set) var lastUpdated: Date = Date()

    private var timer: Timer?
    private let userDefaults: UserDefaults?

    public init(userDefaults: UserDefaults? = UserDefaults.standard) {
        self.userDefaults = userDefaults
        self.isAwayMode = userDefaults?.bool(forKey: "WakeMeUp_isAwayMode") ?? false
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
