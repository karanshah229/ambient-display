import Foundation

public final class PowerAssertionManager {
    public static let shared = PowerAssertionManager()

    private var activityToken: NSObjectProtocol?
    private let lock = NSLock()

    public private(set) var isAsserted: Bool = false

    private init() {}

    /// Acquires power assertions preventing both display sleep and system sleep,
    /// as well as disabling App Nap throttling for this process.
    /// This guarantees the MacBook Air and connected external Dell monitors stay awake and active.
    public func acquire(reason: String = "WakeMeUp Active Sleep Countdown") {
        lock.lock()
        defer { lock.unlock() }

        guard !isAsserted else { return }

        // Foundation's beginActivity with [.idleDisplaySleepDisabled, .idleSystemSleepDisabled]
        // directly tells powerd to create both PreventUserIdleDisplaySleep and PreventUserIdleSystemSleep assertions.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,
                .idleDisplaySleepDisabled,
                .idleSystemSleepDisabled
            ],
            reason: reason
        )

        isAsserted = (activityToken != nil)

        if isAsserted {
            print("[PowerAssertionManager] Power assertions acquired successfully. MacBook Air and monitors will not sleep.")
        } else {
            print("[PowerAssertionManager] Warning: Failed to acquire power assertions.")
        }
    }

    /// Releases power assertions, allowing MacBook Air and displays to sleep normally.
    public func release() {
        lock.lock()
        defer { lock.unlock() }

        guard isAsserted else { return }

        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }

        isAsserted = false
        print("[PowerAssertionManager] Power assertions released. System and display idle sleep restored.")
    }

    deinit {
        release()
    }
}
