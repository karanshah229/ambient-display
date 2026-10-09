import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public static let shared = AppDelegate()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as menu bar accessory app
        NSApp.setActivationPolicy(.accessory)

        // Initialize managers
        _ = MenuBarManager.shared
        _ = WindowManager.shared

        // Start HTTP server
        LocalHTTPServer.shared.start()

        print("[AppDelegate] Ambient Display macOS application initialized successfully.")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.synchronize()
        PowerAssertionManager.shared.release()
        LocalHTTPServer.shared.stop()
        print("[AppDelegate] Ambient Display application terminated.")
    }
}
