import AppKit
import SwiftUI
import Combine

@MainActor
public final class WindowManager: ObservableObject {
    public static let shared = WindowManager()

    private var displayWindows: [NSWindow] = []
    private var cancellables = Set<AnyCancellable>()
    private let appState = AppState.shared

    private init() {
        setupStateSubscription()
        setupScreenChangeObserver()
    }

    private func setupStateSubscription() {
        appState.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.handleStateChanged(newState)
            }
            .store(in: &cancellables)
    }

    private func setupScreenChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                print("[WindowManager] Screen configuration changed. Re-mirroring across \(NSScreen.screens.count) screen(s)...")
                if self.appState.state != .idle {
                    self.showMirroredWindows()
                }
            }
        }
    }

    private func handleStateChanged(_ state: SessionState) {
        switch state {
        case .sleeping, .wakeUpReady:
            PowerAssertionManager.shared.acquire()
            showMirroredWindows()
        case .idle:
            PowerAssertionManager.shared.release()
            hideAllWindows()
        }
    }

    /// Mirrors the ambient countdown display across all connected screens
    public func showMirroredWindows() {
        // Close existing windows cleanly
        hideAllWindows()

        let screens = NSScreen.screens
        print("[WindowManager] Showing mirrored ambient display on \(screens.count) screen(s):")

        for (index, screen) in screens.enumerated() {
            let screenName = screen.localizedName
            print("  - Display \(index + 1): \(screenName) frame: \(screen.frame) (\(Int(screen.frame.width))x\(Int(screen.frame.height)))")

            let window = createOverlayWindow(for: screen)
            let hostingController = NSHostingController(
                rootView: AmbientDisplayView(appState: appState, screenName: screenName)
            )
            
            window.contentViewController = hostingController
            // CRITICAL: Ensure frame is explicitly set AFTER contentViewController is assigned,
            // otherwise AppKit collapses borderless hosting controller windows to 0x0!
            hostingController.view.frame = NSRect(origin: .zero, size: screen.frame.size)
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            window.makeKey()
            displayWindows.append(window)
        }

        // Activate application so overlays appear in front of all open windows
        NSApp.activate(ignoringOtherApps: true)
    }

    public func hideAllWindows() {
        for window in displayWindows {
            window.orderOut(nil)
        }
        displayWindows.removeAll()
    }

    private func createOverlayWindow(for screen: NSScreen) -> NSWindow {
        let window = KeyCatchingWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        // Float above all application windows, menu bars, and full-screen spaces
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = false

        return window
    }
}

/// Borderless NSWindow subclass that captures Escape key to dismiss/wake up
private final class KeyCatchingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            Task { @MainActor in
                AppState.shared.stopSleep()
            }
        } else {
            super.keyDown(with: event)
        }
    }
}
