import AppKit
import SwiftUI
import Combine

public struct ActiveMessage: Identifiable {
    public let id: UUID
    public let text: String
    public let targetDisplayId: String
    public let durationSeconds: Int?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        targetDisplayId: String = "all",
        durationSeconds: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.targetDisplayId = targetDisplayId
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }
}

public enum ScreenDisplayMode {
    case idle
    case sleeping
    case message(ActiveMessage)
}

@MainActor
public final class WindowManager: ObservableObject {
    public static let shared = WindowManager()

    private var screenWindows: [String: NSWindow] = [:]
    private var screenModes: [String: ScreenDisplayMode] = [:]
    private var activeMessages: [UUID: ActiveMessage] = [:]
    private var messageTimers: [UUID: Timer] = [:]

    private var cancellables = Set<AnyCancellable>()
    private let appState = AppState.shared

    private init() {
        setupStateSubscription()
        setupScreenChangeObserver()
    }

    public static func displayId(for screen: NSScreen) -> String {
        let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return String(screenNumber)
    }

    public func currentMode(forScreenId screenId: String) -> ScreenDisplayMode {
        screenModes[screenId] ?? .idle
    }

    public func hasActiveMessages() -> Bool {
        !activeMessages.isEmpty
    }

    public func getActiveMessagesList() -> [ActiveMessageDTO] {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        return activeMessages.values.map { msg in
            var remaining: Int? = nil
            if let duration = msg.durationSeconds, duration > 0 {
                let elapsed = Int(now.timeIntervalSince(msg.createdAt))
                remaining = max(0, duration - elapsed)
            }
            return ActiveMessageDTO(
                id: msg.id.uuidString,
                text: msg.text,
                target_display_id: msg.targetDisplayId,
                duration_seconds: msg.durationSeconds,
                created_at: formatter.string(from: msg.createdAt),
                remaining_seconds: remaining
            )
        }
    }

    public func getConnectedDisplays() -> [DisplayInfoDTO] {
        let mainScreen = NSScreen.main
        return NSScreen.screens.enumerated().map { (index, screen) in
            let id = Self.displayId(for: screen)
            let isMain = (screen == mainScreen)
            let width = Int(screen.frame.width)
            let height = Int(screen.frame.height)
            let isIgnored = appState.isDisplayIgnored(screen: screen)
            let modeStr: String
            switch screenModes[id] ?? .idle {
            case .idle: modeStr = "idle"
            case .sleeping: modeStr = "sleeping"
            case .message: modeStr = "message"
            }
            return DisplayInfoDTO(
                id: id,
                name: screen.localizedName,
                is_main: isMain,
                width: width,
                height: height,
                active_mode: modeStr,
                is_ignored: isIgnored
            )
        }
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
                print("[WindowManager] Screen configuration changed. Available screens: \(NSScreen.screens.count)")
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
            if !hasActiveMessages() {
                PowerAssertionManager.shared.release()
            }
            hideSleepWindows()
        }
    }

    // MARK: - Sleep Display Windows

    /// Shows mirrored ambient countdown on all eligible screens (respecting mutual exclusion if screen has active message)
    public func showMirroredWindows() {
        let screens = NSScreen.screens
        print("[WindowManager] Refreshing sleep displays on \(screens.count) screen(s):")

        for (index, screen) in screens.enumerated() {
            let screenId = Self.displayId(for: screen)
            let screenName = screen.localizedName

            if appState.isDisplayIgnored(screen: screen) {
                print("  - Display \(index + 1): \(screenName) (ID: \(screenId)) [IGNORED]")
                hideWindow(forScreenId: screenId)
                continue
            }

            // Mutual exclusion: if screen already has an active custom message, do not overwrite it
            if case .message = screenModes[screenId] {
                print("  - Display \(index + 1): \(screenName) (ID: \(screenId)) [BUSY: Showing Custom Message]")
                continue
            }

            print("  - Display \(index + 1): \(screenName) (ID: \(screenId)) frame: \(screen.frame)")
            screenModes[screenId] = .sleeping
            presentAmbientView(on: screen, screenId: screenId)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentAmbientView(on screen: NSScreen, screenId: String) {
        let window = screenWindows[screenId] ?? createOverlayWindow(for: screen, screenId: screenId)
        screenWindows[screenId] = window

        let hostingController = NSHostingController(
            rootView: AmbientDisplayView(appState: appState, screenName: screen.localizedName)
        )
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        hostingController.view.frame = NSRect(origin: .zero, size: screen.frame.size)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        window.makeKey()
    }

    public func hideSleepWindows() {
        for (screenId, mode) in screenModes {
            if case .sleeping = mode {
                screenModes[screenId] = .idle
                hideWindow(forScreenId: screenId)
            }
        }
    }

    public func hideAllWindows() {
        for timer in messageTimers.values {
            timer.invalidate()
        }
        messageTimers.removeAll()
        activeMessages.removeAll()
        screenModes.removeAll()

        for (_, window) in screenWindows {
            window.orderOut(nil)
        }
        screenWindows.removeAll()
        PowerAssertionManager.shared.release()
    }

    private func hideWindow(forScreenId screenId: String) {
        if let window = screenWindows.removeValue(forKey: screenId) {
            window.orderOut(nil)
        }
    }

    // MARK: - Custom Screen Messages

    @discardableResult
    public func showMessage(
        text: String,
        targetDisplayId: String = "all",
        durationSeconds: Int? = nil
    ) -> ActiveMessageDTO {
        let targetId = targetDisplayId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let effectiveTarget = targetId.isEmpty ? "all" : targetId

        let message = ActiveMessage(
            text: text,
            targetDisplayId: effectiveTarget,
            durationSeconds: durationSeconds
        )
        activeMessages[message.id] = message

        // Determine targeted screens
        let screens: [NSScreen]
        if effectiveTarget == "all" {
            screens = NSScreen.screens.filter { !appState.isDisplayIgnored(screen: $0) }
        } else {
            let matched = NSScreen.screens.filter { Self.displayId(for: $0) == effectiveTarget }
            screens = matched.isEmpty ? NSScreen.screens : matched
        }

        print("[WindowManager] Displaying message '\(text)' on \(screens.count) screen(s) (target: \(effectiveTarget), duration: \(durationSeconds?.description ?? "persistent"))")

        for screen in screens {
            let screenId = Self.displayId(for: screen)
            screenModes[screenId] = .message(message)
            presentMessageView(on: screen, screenId: screenId, message: message)
        }

        // Acquire power assertion so screens do not sleep while message is displayed
        PowerAssertionManager.shared.acquire()
        NSApp.activate(ignoringOtherApps: true)

        // Set up timer if timed toast
        if let duration = durationSeconds, duration > 0 {
            let msgId = message.id
            let timer = Timer.scheduledTimer(withTimeInterval: Double(duration), repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismissMessageById(msgId)
                }
            }
            messageTimers[msgId] = timer
        }

        let formatter = ISO8601DateFormatter()
        return ActiveMessageDTO(
            id: message.id.uuidString,
            text: message.text,
            target_display_id: message.targetDisplayId,
            duration_seconds: message.durationSeconds,
            created_at: formatter.string(from: message.createdAt),
            remaining_seconds: durationSeconds
        )
    }

    private func presentMessageView(on screen: NSScreen, screenId: String, message: ActiveMessage) {
        let window = screenWindows[screenId] ?? createOverlayWindow(for: screen, screenId: screenId)
        screenWindows[screenId] = window

        let hostingController = NSHostingController(
            rootView: MessageOverlayView(
                text: message.text,
                screenName: screen.localizedName,
                createdAt: message.createdAt,
                durationSeconds: message.durationSeconds,
                onDismiss: { [weak self] in
                    // Dismiss on any one screen dismisses message on every screen
                    self?.dismissMessage(targetDisplayId: "all")
                }
            )
        )
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        hostingController.view.frame = NSRect(origin: .zero, size: screen.frame.size)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        window.makeKey()
    }

    public func dismissMessage(targetDisplayId: String = "all") {
        let targetId = targetDisplayId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if targetId == "all" || targetId.isEmpty {
            for timer in messageTimers.values { timer.invalidate() }
            messageTimers.removeAll()
            activeMessages.removeAll()

            for screen in NSScreen.screens {
                let screenId = Self.displayId(for: screen)
                if case .message = screenModes[screenId] {
                    revertScreenPostMessage(screen: screen, screenId: screenId)
                }
            }
        } else {
            if NSScreen.screens.contains(where: { Self.displayId(for: $0) == targetId }) {
                dismissMessage(onScreenId: targetId)
            }
        }

        if !hasActiveMessages() && appState.state == .idle {
            PowerAssertionManager.shared.release()
        }
    }

    public func dismissMessage(onScreenId screenId: String) {
        guard let screen = NSScreen.screens.first(where: { Self.displayId(for: $0) == screenId }) else { return }
        if case .message(let msg) = screenModes[screenId] {
            messageTimers[msg.id]?.invalidate()
            messageTimers.removeValue(forKey: msg.id)
            activeMessages.removeValue(forKey: msg.id)
        }
        revertScreenPostMessage(screen: screen, screenId: screenId)

        if !hasActiveMessages() && appState.state == .idle {
            PowerAssertionManager.shared.release()
        }
    }

    private func dismissMessageById(_ id: UUID) {
        guard activeMessages.removeValue(forKey: id) != nil else { return }
        messageTimers[id]?.invalidate()
        messageTimers.removeValue(forKey: id)

        for screen in NSScreen.screens {
            let screenId = Self.displayId(for: screen)
            if case .message(let activeMsg) = screenModes[screenId], activeMsg.id == id {
                revertScreenPostMessage(screen: screen, screenId: screenId)
            }
        }

        if !hasActiveMessages() && appState.state == .idle {
            PowerAssertionManager.shared.release()
        }
    }

    /// Reverts a screen back to sleep countdown if sleep is active, or closes window if idle
    private func revertScreenPostMessage(screen: NSScreen, screenId: String) {
        if appState.state == .sleeping || appState.state == .wakeUpReady {
            print("[WindowManager] Screen \(screenId) reverted from message to active sleep display.")
            screenModes[screenId] = .sleeping
            presentAmbientView(on: screen, screenId: screenId)
        } else {
            print("[WindowManager] Screen \(screenId) message dismissed (idle desktop restored).")
            screenModes[screenId] = .idle
            hideWindow(forScreenId: screenId)
        }
    }

    private func createOverlayWindow(for screen: NSScreen, screenId: String) -> NSWindow {
        KeyCatchingWindow(screen: screen, screenId: screenId)
    }
}

/// Borderless NSWindow subclass that covers the target monitor and captures Escape to dismiss
private final class KeyCatchingWindow: NSWindow {
    let targetScreen: NSScreen
    let screenId: String

    init(screen: NSScreen, screenId: String) {
        self.targetScreen = screen
        self.screenId = screenId
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Float above all application windows, menu bars, full-screen spaces, and macOS lock screen shield (level 2001)
        self.level = NSWindow.Level(rawValue: 2002)
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.backgroundColor = .black
        self.isOpaque = true
        self.hasShadow = false
        self.ignoresMouseEvents = false
        super.setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(targetScreen.frame, display: flag)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            Task { @MainActor in
                let mode = WindowManager.shared.currentMode(forScreenId: screenId)
                switch mode {
                case .message:
                    // ESC on any screen dismisses message on every screen
                    WindowManager.shared.dismissMessage(targetDisplayId: "all")
                case .sleeping:
                    // ESC on any screen dismisses alarm clock / sleep session on every screen
                    AppState.shared.stopSleep()
                case .idle:
                    if WindowManager.shared.hasActiveMessages() {
                        WindowManager.shared.dismissMessage(targetDisplayId: "all")
                    } else if AppState.shared.state != .idle {
                        AppState.shared.stopSleep()
                    }
                }
            }
        } else {
            super.keyDown(with: event)
        }
    }
}
