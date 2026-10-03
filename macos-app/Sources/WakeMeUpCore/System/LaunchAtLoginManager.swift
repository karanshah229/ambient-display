import Foundation
import ServiceManagement
import Combine

/// Manages macOS Launch at Login via ServiceManagement SMAppService (macOS 13+)
@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    public static let shared = LaunchAtLoginManager()

    @Published public private(set) var isEnabled: Bool = false

    private init() {
        refresh()
    }

    /// Queries macOS ServiceManagement for current registration status
    public func refresh() {
        if #available(macOS 13.0, *) {
            self.isEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    /// Enables or disables launch at login
    public func setEnabled(_ enabled: Bool) {
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
                self.isEnabled = (SMAppService.mainApp.status == .enabled)
            } catch {
                print("[LaunchAtLogin] Error updating launch item: \(error)")
                refresh()
            }
        }
    }

    public func toggle() {
        setEnabled(!isEnabled)
    }
}
