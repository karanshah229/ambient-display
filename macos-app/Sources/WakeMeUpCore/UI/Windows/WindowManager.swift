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

public struct ActiveCanvas: Identifiable {
    public let id: UUID
    public let type: CanvasPayloadType
    public let title: String
    public let subtitle: String?
    public let mediaUrl: String?
    public let theme: String?
    public let dismissPolicy: DismissPolicy
    public let targetDisplayId: String
    public let durationSeconds: Int?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        type: CanvasPayloadType = .billboard,
        title: String,
        subtitle: String? = nil,
        mediaUrl: String? = nil,
        theme: String? = nil,
        dismissPolicy: DismissPolicy = .escAny,
        targetDisplayId: String = "all",
        durationSeconds: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.mediaUrl = mediaUrl
        self.theme = theme
        self.dismissPolicy = dismissPolicy
        self.targetDisplayId = targetDisplayId
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }

    public var asActiveMessage: ActiveMessage {
        ActiveMessage(
            id: id,
            text: subtitle != nil ? "\(title)\n\(subtitle!)" : title,
            targetDisplayId: targetDisplayId,
            durationSeconds: durationSeconds,
            createdAt: createdAt
        )
    }
}

public enum ScreenDisplayMode {
    case idle
    case sleeping
    case message(ActiveMessage)
    case canvas(ActiveCanvas)
}

@MainActor
public final class WindowManager: ObservableObject {
    public static let shared = WindowManager()

    private var screenWindows: [String: NSWindow] = [:]
    private var screenModes: [String: ScreenDisplayMode] = [:]
    private var activeCanvases: [UUID: ActiveCanvas] = [:]
    private var canvasTimers: [UUID: Timer] = [:]

    private var cancellables = Set<AnyCancellable>()
    private let appState = AppState.shared
    public var onCanvasDismissed: ((String) -> Void)?

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
        !activeCanvases.isEmpty
    }

    public func getActiveMessagesList() -> [ActiveMessageDTO] {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        return activeCanvases.values.map { c in
            var remaining: Int? = nil
            if let duration = c.durationSeconds, duration > 0 {
                let elapsed = Int(now.timeIntervalSince(c.createdAt))
                remaining = max(0, duration - elapsed)
            }
            let text = c.subtitle != nil ? "\(c.title) - \(c.subtitle!)" : c.title
            return ActiveMessageDTO(
                id: c.id.uuidString,
                text: text,
                target_display_id: c.targetDisplayId,
                duration_seconds: c.durationSeconds,
                created_at: formatter.string(from: c.createdAt),
                remaining_seconds: remaining
            )
        }
    }

    public func getActiveCanvasesList() -> [CanvasPayloadDTO] {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        return activeCanvases.values.map { c in
            var remaining: Int? = nil
            if let duration = c.durationSeconds, duration > 0 {
                let elapsed = Int(now.timeIntervalSince(c.createdAt))
                remaining = max(0, duration - elapsed)
            }
            return CanvasPayloadDTO(
                id: c.id.uuidString,
                type: c.type.rawValue,
                title: c.title,
                subtitle: c.subtitle,
                media_url: c.mediaUrl,
                theme: c.theme,
                dismiss_policy: c.dismissPolicy.rawValue,
                target_display_id: c.targetDisplayId,
                duration_seconds: c.durationSeconds,
                created_at: formatter.string(from: c.createdAt),
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
            case .message, .canvas: modeStr = "message"
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

    /// Shows mirrored ambient countdown on all eligible screens (respecting mutual exclusion if screen has active message/canvas)
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

            // Mutual exclusion: if screen already has an active custom canvas/message, do not overwrite it
            switch screenModes[screenId] {
            case .canvas, .message:
                print("  - Display \(index + 1): \(screenName) (ID: \(screenId)) [BUSY: Showing Custom Canvas]")
                continue
            default:
                break
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
        for timer in canvasTimers.values {
            timer.invalidate()
        }
        canvasTimers.removeAll()
        activeCanvases.removeAll()
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

    // MARK: - Ambient Surface Canvas & Screen Messages

    @discardableResult
    public func showCanvas(
        type: CanvasPayloadType = .billboard,
        title: String,
        subtitle: String? = nil,
        mediaUrl: String? = nil,
        theme: String? = nil,
        dismissPolicy: DismissPolicy = .escAny,
        targetDisplayId: String = "all",
        durationSeconds: Int? = nil
    ) -> CanvasPayloadDTO {
        let targetId = targetDisplayId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let effectiveTarget = targetId.isEmpty ? "all" : targetId

        let canvas = ActiveCanvas(
            type: type,
            title: title,
            subtitle: subtitle,
            mediaUrl: mediaUrl,
            theme: theme,
            dismissPolicy: dismissPolicy,
            targetDisplayId: effectiveTarget,
            durationSeconds: durationSeconds
        )
        // Determine targeted screens
        let screens: [NSScreen]
        if effectiveTarget == "all" {
            screens = NSScreen.screens.filter { !appState.isDisplayIgnored(screen: $0) }
            // If broadcasting to all screens, clear previous active canvases & timers
            for timer in canvasTimers.values { timer.invalidate() }
            canvasTimers.removeAll()
            activeCanvases.removeAll()
        } else {
            let matched = NSScreen.screens.filter { Self.displayId(for: $0) == effectiveTarget }
            screens = matched.isEmpty ? NSScreen.screens : matched
            // If targeting specific screen, remove prior canvas occupying that screen
            for screen in screens {
                let sId = Self.displayId(for: screen)
                if case .canvas(let prior) = screenModes[sId] {
                    canvasTimers[prior.id]?.invalidate()
                    canvasTimers.removeValue(forKey: prior.id)
                    activeCanvases.removeValue(forKey: prior.id)
                }
            }
        }

        activeCanvases[canvas.id] = canvas

        print("[WindowManager] Displaying canvas [\(type.rawValue)] '\(title)' on \(screens.count) screen(s) (target: \(effectiveTarget), policy: \(dismissPolicy.rawValue), duration: \(durationSeconds?.description ?? "persistent"))")


        for screen in screens {
            let screenId = Self.displayId(for: screen)
            screenModes[screenId] = .canvas(canvas)
            presentCanvasView(on: screen, screenId: screenId, canvas: canvas)
        }

        // Acquire power assertion so screens do not sleep while canvas is active
        PowerAssertionManager.shared.acquire()
        NSApp.activate(ignoringOtherApps: true)

        // Set up timer if timed canvas
        if let duration = durationSeconds, duration > 0 {
            let canvasId = canvas.id
            let timer = Timer.scheduledTimer(withTimeInterval: Double(duration), repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismissCanvasById(canvasId)
                }
            }
            canvasTimers[canvasId] = timer
        }

        let formatter = ISO8601DateFormatter()
        return CanvasPayloadDTO(
            id: canvas.id.uuidString,
            type: canvas.type.rawValue,
            title: canvas.title,
            subtitle: canvas.subtitle,
            media_url: canvas.mediaUrl,
            theme: canvas.theme,
            dismiss_policy: canvas.dismissPolicy.rawValue,
            target_display_id: canvas.targetDisplayId,
            duration_seconds: canvas.durationSeconds,
            created_at: formatter.string(from: canvas.createdAt),
            remaining_seconds: durationSeconds
        )
    }

    /// Backward-compatible bridge for legacy message API
    @discardableResult
    public func showMessage(
        text: String,
        targetDisplayId: String = "all",
        durationSeconds: Int? = nil
    ) -> ActiveMessageDTO {
        let canvasDto = showCanvas(
            type: .billboard,
            title: text,
            subtitle: nil,
            mediaUrl: nil,
            theme: nil,
            dismissPolicy: .escAny,
            targetDisplayId: targetDisplayId,
            durationSeconds: durationSeconds
        )
        return ActiveMessageDTO(
            id: canvasDto.id,
            text: canvasDto.title ?? text,
            target_display_id: canvasDto.target_display_id,
            duration_seconds: canvasDto.duration_seconds,
            created_at: canvasDto.created_at,
            remaining_seconds: canvasDto.remaining_seconds
        )
    }

    private func presentCanvasView(on screen: NSScreen, screenId: String, canvas: ActiveCanvas) {
        let window = screenWindows[screenId] ?? createOverlayWindow(for: screen, screenId: screenId)
        screenWindows[screenId] = window

        let hostingController = NSHostingController(
            rootView: CanvasOverlayView(
                canvas: canvas,
                screenName: screen.localizedName,
                onDismiss: { [weak self] in
                    if canvas.dismissPolicy != .phoneOnly {
                        // Dismiss on any one screen dismisses canvas on every screen
                        self?.dismissCanvas(targetDisplayId: "all")
                    }
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

    public func dismissCanvas(targetDisplayId: String = "all") {
        let targetId = targetDisplayId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if targetId == "all" || targetId.isEmpty {
            for timer in canvasTimers.values { timer.invalidate() }
            canvasTimers.removeAll()
            activeCanvases.removeAll()

            for screen in NSScreen.screens {
                let screenId = Self.displayId(for: screen)
                switch screenModes[screenId] {
                case .canvas, .message:
                    revertScreenPostCanvas(screen: screen, screenId: screenId)
                default:
                    break
                }
            }
        } else {
            if NSScreen.screens.contains(where: { Self.displayId(for: $0) == targetId }) {
                dismissCanvas(onScreenId: targetId)
            }
        }

        if !hasActiveMessages() && appState.state == .idle {
            PowerAssertionManager.shared.release()
        }

        onCanvasDismissed?(targetId)
    }

    public func dismissCanvas(onScreenId screenId: String) {
        guard let screen = NSScreen.screens.first(where: { Self.displayId(for: $0) == screenId }) else { return }
        switch screenModes[screenId] {
        case .canvas(let c):
            canvasTimers[c.id]?.invalidate()
            canvasTimers.removeValue(forKey: c.id)
            activeCanvases.removeValue(forKey: c.id)
        case .message(let m):
            canvasTimers[m.id]?.invalidate()
            canvasTimers.removeValue(forKey: m.id)
            activeCanvases.removeValue(forKey: m.id)
        default:
            break
        }
        revertScreenPostCanvas(screen: screen, screenId: screenId)

        if !hasActiveMessages() && appState.state == .idle {
            PowerAssertionManager.shared.release()
        }
    }

    private func dismissCanvasById(_ id: UUID) {
        guard activeCanvases.removeValue(forKey: id) != nil else { return }
        canvasTimers[id]?.invalidate()
        canvasTimers.removeValue(forKey: id)

        for screen in NSScreen.screens {
            let screenId = Self.displayId(for: screen)
            switch screenModes[screenId] {
            case .canvas(let c) where c.id == id:
                revertScreenPostCanvas(screen: screen, screenId: screenId)
            case .message(let m) where m.id == id:
                revertScreenPostCanvas(screen: screen, screenId: screenId)
            default:
                break
            }
        }

        if !hasActiveMessages() && appState.state == .idle {
            PowerAssertionManager.shared.release()
        }
    }

    public func dismissMessage(targetDisplayId: String = "all") {
        dismissCanvas(targetDisplayId: targetDisplayId)
    }

    public func dismissMessage(onScreenId screenId: String) {
        dismissCanvas(onScreenId: screenId)
    }

    /// Reverts a screen back to sleep countdown if sleep is active, or closes window if idle
    private func revertScreenPostCanvas(screen: NSScreen, screenId: String) {
        if appState.state == .sleeping || appState.state == .wakeUpReady {
            print("[WindowManager] Screen \(screenId) reverted from canvas to active sleep display.")
            screenModes[screenId] = .sleeping
            presentAmbientView(on: screen, screenId: screenId)
        } else {
            print("[WindowManager] Screen \(screenId) canvas dismissed (idle desktop restored).")
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
                case .canvas(let canvas):
                    if canvas.dismissPolicy == .phoneOnly {
                        // Phone-only policy rejects ESC dismissal
                        NSSound.beep()
                        print("[WindowManager] ESC ignored: Canvas is locked (phone_only dismiss policy)")
                    } else {
                        // ESC on any screen dismisses canvas on every screen
                        WindowManager.shared.dismissCanvas(targetDisplayId: "all")
                    }
                case .message:
                    // ESC on any screen dismisses message on every screen
                    WindowManager.shared.dismissCanvas(targetDisplayId: "all")
                case .sleeping:
                    // ESC on any screen dismisses alarm clock / sleep session on every screen
                    AppState.shared.stopSleep()
                case .idle:
                    if WindowManager.shared.hasActiveMessages() {
                        WindowManager.shared.dismissCanvas(targetDisplayId: "all")
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
