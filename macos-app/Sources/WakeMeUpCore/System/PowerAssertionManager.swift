import Foundation
import IOKit.pwr_mgt

public final class PowerAssertionManager {
    public static let shared = PowerAssertionManager()

    private var activityToken: NSObjectProtocol?
    private var displayAssertionID: IOPMAssertionID = 0
    private let lock = NSLock()

    public private(set) var isAsserted: Bool = false

    private init() {}

    /// Explicitly tells macOS powerd that user activity occurred and wakes sleeping displays.
    /// Works even when the Mac screen is locked and monitors are in DPMS sleep.
    public func wakeDisplays() {
        var userActivityID: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity(
            "WakeMeUp Remote Trigger" as CFString,
            kIOPMUserActiveLocal,
            &userActivityID
        )

        // Run caffeinate -u -t 2 asynchronously to guarantee display power-up from standby
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            proc.arguments = ["-u", "-t", "2"]
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    /// Acquires power assertions preventing both display sleep and system sleep,
    /// as well as disabling App Nap throttling for this process.
    /// This guarantees the MacBook Air and connected external Dell monitors stay awake and active.
    public func acquire(reason: String = "WakeMeUp Active Sleep Countdown") {
        lock.lock()
        defer { lock.unlock() }

        // First wake displays if they are asleep
        wakeDisplays()

        guard !isAsserted else { return }

        // 1. Foundation's beginActivity with [.idleDisplaySleepDisabled, .idleSystemSleepDisabled]
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,
                .idleDisplaySleepDisabled,
                .idleSystemSleepDisabled
            ],
            reason: reason
        )

        // 2. Direct IOKit assertion to guarantee displays stay on under locked session
        var assertionID: IOPMAssertionID = 0
        let ret = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        if ret == kIOReturnSuccess {
            displayAssertionID = assertionID
        }

        isAsserted = (activityToken != nil) || (displayAssertionID != 0)

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

        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }

        isAsserted = false
        print("[PowerAssertionManager] Power assertions released. System and display idle sleep restored.")
    }

    deinit {
        release()
    }
}
