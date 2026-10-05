import Foundation
import ServiceManagement
import Combine

/// Manages macOS Launch at Login via ServiceManagement SMAppService (macOS 13+)
@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    public static let shared = LaunchAtLoginManager()

    @Published public private(set) var isEnabled: Bool = false

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = AppState.defaultUserDefaults) {
        self.userDefaults = userDefaults
        let requested = userDefaults.bool(forKey: "WakeMeUp_launchAtLogin")
        self.isEnabled = requested
        refresh()
    }

    /// Queries macOS ServiceManagement for current registration status and synchronizes with user preference
    public func refresh() {
        let requested = userDefaults.bool(forKey: "WakeMeUp_launchAtLogin")
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            if requested && status != .enabled {
                // User requested launch at login, re-register if registration dropped due to app update or rebuild
                do {
                    try SMAppService.mainApp.register()
                    print("[LaunchAtLogin] Restored registration with SMAppService.")
                    self.isEnabled = true
                } catch {
                    print("[LaunchAtLogin] Warning: Failed to re-register with SMAppService: \(error)")
                    // Keep enabled true if user explicitly requested it, even if ad-hoc dev signing requires approval
                    self.isEnabled = (SMAppService.mainApp.status == .enabled) || requested
                }
            } else if !requested && status == .enabled {
                try? SMAppService.mainApp.unregister()
                self.isEnabled = false
            } else {
                self.isEnabled = (status == .enabled) || requested
            }
        } else {
            self.isEnabled = requested
        }
    }

    /// Enables or disables launch at login and saves to persistent storage
    public func setEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: "WakeMeUp_launchAtLogin")
        userDefaults.synchronize()
        if userDefaults != UserDefaults.standard {
            UserDefaults.standard.set(enabled, forKey: "WakeMeUp_launchAtLogin")
            UserDefaults.standard.synchronize()
        }
        self.isEnabled = enabled

        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                        print("[LaunchAtLogin] Successfully registered with SMAppService.")
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                        print("[LaunchAtLogin] Successfully unregistered from SMAppService.")
                    }
                }
            } catch {
                print("[LaunchAtLogin] Error updating launch item: \(error)")
            }
        }
    }

    public func toggle() {
        setEnabled(!isEnabled)
    }
}
