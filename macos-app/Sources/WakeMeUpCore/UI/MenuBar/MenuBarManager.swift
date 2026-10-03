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
            statusTitle = "Status: WAKE ME UP (Alarm Ready)"
        case .sleeping:
            if let session = appState.currentSession {
                statusTitle = "Status: Sleeping (Wake at \(session.formattedTargetTime))"
            } else {
                statusTitle = "Status: Sleeping"
            }
        case .idle:
            statusTitle = appState.isAwayMode ? "Status: Away Mode (Displays Disabled)" : "Status: Idle (Listening on port 8321)"
        }

        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // 2. Sleep Actions
        if appState.state == .idle {
            let startItem = NSMenuItem(title: "Start Sleep Now (7.5h Target)", action: #selector(startSleepAction), keyEquivalent: "s")
            startItem.target = self
            menu.addItem(startItem)
        } else {
            let stopItem = NSMenuItem(title: "Stop / I'm Awake", action: #selector(stopSleepAction), keyEquivalent: "w")
            stopItem.target = self
            menu.addItem(stopItem)
        }

        // 3. Test Preview
        let testItem = NSMenuItem(title: "Test Monitor Display (10s Preview)", action: #selector(testAction), keyEquivalent: "t")
        testItem.target = self
        menu.addItem(testItem)

        menu.addItem(NSMenuItem.separator())

        // 4. Away Mode Toggle
        let awayItem = NSMenuItem(title: "Away Mode (Disable Displays)", action: #selector(toggleAwayAction), keyEquivalent: "a")
        awayItem.target = self
        awayItem.state = appState.isAwayMode ? .on : .off
        menu.addItem(awayItem)

        // 5. Start at Login Toggle
        let loginManager = LaunchAtLoginManager.shared
        loginManager.refresh()
        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLaunchAtLoginAction), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginManager.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        // 6. Preferences
        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferencesAction), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        // 7. Detected Screens info
        let screens = NSScreen.screens
        let screensInfo = "Connected Displays: \(screens.count) (\(screens.map { $0.localizedName }.joined(separator: ", ")))"
        let screensItem = NSMenuItem(title: screensInfo, action: nil, keyEquivalent: "")
        screensItem.isEnabled = false
        menu.addItem(screensItem)

        menu.addItem(NSMenuItem.separator())

        // 8. Quit
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
