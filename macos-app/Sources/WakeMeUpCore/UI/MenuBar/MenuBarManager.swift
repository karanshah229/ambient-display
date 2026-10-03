import AppKit
import Combine

@MainActor
public final class MenuBarManager: NSObject, NSMenuDelegate {
    public static let shared = MenuBarManager()

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var cancellables = Set<AnyCancellable>()
    private let appState = AppState.shared

    private override init() {
        super.init()
        setupStatusItem()
        setupMenu()
        setupBindings()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bed.double.fill", accessibilityDescription: "Wake Me Up")
            button.imagePosition = .imageLeading
        }
    }

    private func setupMenu() {
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshMenuItems()
    }

    private func setupBindings() {
        Publishers.CombineLatest4(appState.$state, appState.$isAwayMode, appState.$currentSession, appState.$showCountdownInMenuBar)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatusItemAppearance()
            }
            .store(in: &cancellables)
    }

    private func refreshStatusItemAppearance() {
        guard let button = statusItem.button else { return }

        switch appState.state {
        case .wakeUpReady:
            button.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Wake Up Ready")
            button.title = appState.showCountdownInMenuBar ? " Wake Up!" : ""
        case .sleeping:
            button.image = NSImage(systemSymbolName: "moon.stars.fill", accessibilityDescription: "Sleeping")
            if appState.showCountdownInMenuBar, let session = appState.currentSession {
                button.title = " \(session.formattedTargetTime)"
            } else {
                button.title = ""
            }
        case .idle:
            button.image = NSImage(systemSymbolName: "bed.double.fill", accessibilityDescription: "Wake Me Up")
            button.title = appState.isAwayMode ? " (Away)" : ""
        }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        refreshMenuItems()
    }

    private func refreshMenuItems() {
        menu.removeAllItems()

        // 1. Status Headline
        let statusTitle: String
        switch appState.state {
        case .wakeUpReady:
            statusTitle = "Status: Wake Up Ready!"
        case .sleeping:
            if let session = appState.currentSession {
                statusTitle = "Status: Sleeping (Wake: \(session.formattedTargetTime))"
            } else {
                statusTitle = "Status: Sleeping"
            }
        case .idle:
            statusTitle = appState.isAwayMode ? "Status: Away Mode (Disabled)" : "Status: Idle (Port 8321)"
        }

        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // 2. Sleep Actions
        if appState.state == .idle {
            let durHours = appState.defaultSleepHours
            let durStr = String(format: durHours.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", durHours)
            let startItem = NSMenuItem(title: "Start Sleep (\(durStr)h Target)", action: #selector(startSleepAction), keyEquivalent: "s")
            startItem.target = self
            menu.addItem(startItem)
        } else {
            let stopItem = NSMenuItem(title: "Stop Sleep", action: #selector(stopSleepAction), keyEquivalent: "w")
            stopItem.target = self
            menu.addItem(stopItem)
        }

        // 3. Test Preview
        let testItem = NSMenuItem(title: "Test Ambient (10s)", action: #selector(testAction), keyEquivalent: "t")
        testItem.target = self
        menu.addItem(testItem)

        menu.addItem(NSMenuItem.separator())

        // 4. Start at Login Toggle
        let loginManager = LaunchAtLoginManager.shared
        loginManager.refresh()
        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLaunchAtLoginAction), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginManager.isEnabled ? .on : .off
        menu.addItem(loginItem)

        // 5. Preferences
        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferencesAction), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        // 6. Quit
        let quitItem = NSMenuItem(title: "Quit Wake Me Up", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func startSleepAction() {
        appState.startSleep(bedtime: Date(), durationMinutes: appState.defaultSleepMinutes, reason: "menu_bar_manual")
    }

    @objc private func stopSleepAction() {
        appState.stopSleep()
    }

    @objc private func testAction() {
        appState.startTestMode(durationSeconds: 10)
    }

    @objc private func toggleAwayAction() {
        appState.toggleAwayMode()
    }

    @objc private func toggleLaunchAtLoginAction() {
        LaunchAtLoginManager.shared.toggle()
        refreshMenuItems()
    }

    @objc private func openPreferencesAction() {
        PreferencesWindowController.shared.show()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
