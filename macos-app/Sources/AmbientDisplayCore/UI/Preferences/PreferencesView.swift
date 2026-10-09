import SwiftUI
import AppKit

@MainActor
public struct PreferencesView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject var cloudService = FirebaseCloudService.shared

    @State private var sleepHoursText: String = ""
    @State private var inactivityOffsetText: String = ""
    @State private var nightColor: Color = AmbientTheme.defaultNightColor
    @State private var dawnColor: Color = AmbientTheme.defaultDawnColor
    @State private var wakeColor: Color = AmbientTheme.defaultWakeColor
    @State private var wifiIPAddress: String = "Detecting..."
    @State private var isLoaded: Bool = false

    public init() {}

    public var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            sleepTab
                .tabItem {
                    Label("Sleep Schedule", systemImage: "bed.double")
                }

            displaysTab
                .tabItem {
                    Label("Displays", systemImage: "display.2")
                }

            ambientTab
                .tabItem {
                    Label("Ambient", systemImage: "paintpalette")
                }

            networkTab
                .tabItem {
                    Label("Network", systemImage: "network")
                }

            cloudTab
                .tabItem {
                    Label("Cloud & Devices", systemImage: "icloud")
                }
        }
        .frame(width: 530, height: 580)
        .padding(20)
        .onAppear {
            loadInitialValues()
        }
        .onDisappear {
            commitSleepHours()
            commitOffsetMinutes()
            appState.synchronize()
        }
    }

    private func loadInitialValues() {
        isLoaded = false
        let hours = appState.defaultSleepHours
        sleepHoursText = String(format: hours.truncatingRemainder(dividingBy: 1) == 0 ? "%.1f" : "%.2g", hours)
        inactivityOffsetText = String(format: "%.0f", appState.inactivityOffsetMinutes)

        nightColor = Color(hex: appState.ambientNightColorHex, defaultFallback: AmbientTheme.defaultNightColor)
        dawnColor = Color(hex: appState.ambientDawnColorHex, defaultFallback: AmbientTheme.defaultDawnColor)
        wakeColor = Color(hex: appState.ambientWakeColorHex, defaultFallback: AmbientTheme.defaultWakeColor)

        wifiIPAddress = fetchLocalWiFiIP() ?? "Unavailable (Not connected to Wi-Fi)"
        isLoaded = true
    }

    // MARK: - General Tab
    private var generalTab: some View {
        Form {
            Section(header: Text("Startup & Menu Bar").font(.headline)) {
                Toggle("Launch Ambient Display at Login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .help("Automatically launches Ambient Display when you log into your Mac")

                Text("Keeps the local ambient server and display mirror ready at all times.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Show Target Wake Time in Menu Bar", isOn: $appState.showCountdownInMenuBar)
                    .help("Displays the target wake-up time next to the menu bar icon during sleep")
            }

            Section(header: Text("Away Mode").font(.headline)) {
                Toggle("Enable Away Mode", isOn: $appState.isAwayMode)
                    .help("Suppresses display activation when you are away from home")

                Text("When active, incoming sleep events from your phone will not turn on the external monitors.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Sleep Tab
    private var sleepTab: some View {
        Form {
            Section(header: Text("Target Sleep Duration").font(.headline)) {
                HStack(spacing: 8) {
                    Text("Duration:")
                    TextField("", text: $sleepHoursText)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: sleepHoursText) { newValue in
                            guard isLoaded else { return }
                            if let val = Double(newValue.trimmingCharacters(in: .whitespaces)), val >= 1.0, val <= 16.0 {
                                appState.defaultSleepHours = val
                            }
                        }
                        .onSubmit { commitSleepHours() }
                    Stepper("", value: Binding(
                        get: { appState.defaultSleepHours },
                        set: { newVal in
                            appState.defaultSleepHours = newVal
                            sleepHoursText = String(format: newVal.truncatingRemainder(dividingBy: 1) == 0 ? "%.1f" : "%.2g", newVal)
                        }
                    ), in: 1.0...16.0, step: 0.5)
                    .labelsHidden()
                    Text("hours")
                }

                Text("Default is 7.5 hours (5 × 90-minute ultradian sleep cycles). Custom duration can be any value between 1 and 16 hours.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Eligible Sleep Window").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow sleep detection between:")
                        .font(.subheadline)
                        .foregroundColor(.primary)

                    HStack(spacing: 12) {
                        Picker("Start Time", selection: $appState.sleepWindowStartHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(formatHour(h)).tag(h)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 125)

                        Text("to")
                            .foregroundColor(.secondary)

                        Picker("End Time", selection: $appState.sleepWindowEndHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(formatHour(h)).tag(h)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 125)
                    }
                }

                Text("Phone inactivity outside this window (e.g. at 3 PM) is completely ignored and will never trigger sleep.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Auto-Push Sleep Target Window").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Automatically push target bedtime back between:")
                        .font(.subheadline)
                        .foregroundColor(.primary)

                    HStack(spacing: 12) {
                        Picker("Auto-Push Start", selection: $appState.autoPushWindowStartHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(formatHour(h)).tag(h)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 125)

                        Text("to")
                            .foregroundColor(.secondary)

                        Picker("Auto-Push End", selection: $appState.autoPushWindowEndHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(formatHour(h)).tag(h)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 125)
                    }
                }

                Text("During this early evening window (default 9–11 PM), using your phone automatically rolls your sleep target back. Outside this window, phone use triggers an interactive notification asking before modifying.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Inactivity Compensation").font(.headline)) {
                Toggle("Auto-detect offset from phone system settings", isOn: $appState.autoDetectInactivityOffset)

                if !appState.autoDetectInactivityOffset {
                    HStack(spacing: 8) {
                        Text("Custom Inactivity Offset:")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        TextField("Minutes", text: $inactivityOffsetText)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: inactivityOffsetText) { newValue in
                                guard isLoaded else { return }
                                if let val = Double(newValue.trimmingCharacters(in: .whitespaces)), val >= 0, val <= 120 {
                                    appState.inactivityOffsetMinutes = val
                                }
                            }
                            .onSubmit { commitOffsetMinutes() }
                        Stepper("", value: Binding(
                            get: { appState.inactivityOffsetMinutes },
                            set: { newVal in
                                appState.inactivityOffsetMinutes = newVal
                                inactivityOffsetText = String(format: "%.0f", newVal)
                            }
                        ), in: 0...120, step: 5)
                        .labelsHidden()
                        Text("minutes")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                Text("Compensates for falling asleep mid-movie or while reading before the device display times out. Supported across any Android phone.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func formatHour(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        return "\(h):00 \(ampm)"
    }

    private func commitSleepHours() {
        if let val = Double(sleepHoursText.trimmingCharacters(in: .whitespaces)), val >= 1.0, val <= 16.0 {
            appState.defaultSleepHours = val
        }
        let current = appState.defaultSleepHours
        sleepHoursText = String(format: current.truncatingRemainder(dividingBy: 1) == 0 ? "%.1f" : "%.2g", current)
        appState.synchronize()
    }

    private func commitOffsetMinutes() {
        if let val = Double(inactivityOffsetText.trimmingCharacters(in: .whitespaces)), val >= 0, val <= 120 {
            appState.inactivityOffsetMinutes = val
        }
        inactivityOffsetText = String(format: "%.0f", appState.inactivityOffsetMinutes)
        appState.synchronize()
    }

    // MARK: - Displays Tab
    private var displaysTab: some View {
        Form {
            Section(header: Text("Detected Displays (\(NSScreen.screens.count))").font(.headline)) {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                    let isIgnored = appState.isDisplayIgnored(screen: screen)

                    HStack(spacing: 12) {
                        Image(systemName: isIgnored ? "display.trianglebadge.exclamationmark" : "display")
                            .font(.system(size: 20))
                            .foregroundColor(isIgnored ? .secondary : .blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(screen.localizedName)
                                .fontWeight(.semibold)
                                .foregroundColor(isIgnored ? .secondary : .primary)
                            Text("\(Int(screen.frame.width)) × \(Int(screen.frame.height)) pt")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(action: {
                            appState.toggleDisplayIgnored(screen: screen)
                        }) {
                            Text(isIgnored ? "Enable" : "Ignore Display")
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(isIgnored ? .accentColor : .red)
                    }
                    .padding(.vertical, 4)
                }

                Text("Ignored displays will remain completely unaffected when ambient night or wake-up screens activate.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Ambient Tab
    private var ambientTab: some View {
        Form {
            Section(header: Text("Ambient Theme Presentation").font(.headline)) {
                ColorPicker("Deep Night Glow", selection: $nightColor)
                    .onChange(of: nightColor) { newColor in
                        guard isLoaded else { return }
                        if let hex = newColor.toHex() {
                            appState.ambientNightColorHex = hex
                        }
                    }

                ColorPicker("Dawn Warm Glow", selection: $dawnColor)
                    .onChange(of: dawnColor) { newColor in
                        guard isLoaded else { return }
                        if let hex = newColor.toHex() {
                            appState.ambientDawnColorHex = hex
                        }
                    }

                ColorPicker("Morning Wake-Up Glow", selection: $wakeColor)
                    .onChange(of: wakeColor) { newColor in
                        guard isLoaded else { return }
                        if let hex = newColor.toHex() {
                            appState.ambientWakeColorHex = hex
                        }
                    }

                HStack {
                    Button(action: {
                        appState.startTestMode(durationSeconds: 10)
                    }) {
                        Label("Test Ambient Display (10s)", systemImage: "play.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    Button("Reset to Defaults") {
                        appState.resetAmbientDefaults()
                        nightColor = Color(hex: appState.ambientNightColorHex, defaultFallback: AmbientTheme.defaultNightColor)
                        dawnColor = Color(hex: appState.ambientDawnColorHex, defaultFallback: AmbientTheme.defaultDawnColor)
                        wakeColor = Color(hex: appState.ambientWakeColorHex, defaultFallback: AmbientTheme.defaultWakeColor)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }

            Section(header: Text("Preview Notes").font(.headline)) {
                Text("All themes render over pitch black (#000000) for zero backlight bleed in dark environments. Click \"Test Ambient Display\" to preview the active glow palette across your connected screens.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Network Tab
    private var networkTab: some View {
        Form {
            Section(header: Text("Companion App Connection").font(.headline)) {
                LabeledContent("Wi-Fi IP Address", value: wifiIPAddress)
                LabeledContent("HTTP Port", value: "8321")
                LabeledContent("Bonjour mDNS", value: "_ambientdisplay._tcp (AmbientDisplayMac)")

                Text("Your Android companion app connects to this Mac over your local Wi-Fi network. If DHCP assigns a new IP, Bonjour automatically updates.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Cloud & Devices Tab
    private var cloudTab: some View {
        Form {
            Section(header: Text("Google Account").font(.headline)) {
                if let user = cloudService.currentUser {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName ?? "Google User")
                                .font(.headline)
                            Text(user.email ?? "Signed in")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Sign Out") {
                            cloudService.signOut()
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Connected to Firebase (\(cloudService.projectId.isEmpty ? "Cloud" : cloudService.projectId))")
                            .font(.caption)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign in with Google to sync ambient messages and canvases across all your devices anywhere in the world.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("Google Sign-In is enforced. Sign in from your mobile companion app or use authenticated device pairing.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Ambient Device Identity").font(.headline)) {
                LabeledContent("Device ID", value: cloudService.deviceId)
                LabeledContent("Device Name", value: cloudService.deviceName)
                LabeledContent("Cloud Sync Status", value: cloudService.isConnected ? "Online & Synchronizing" : "Offline")

                if let err = cloudService.syncError {
                    Text("Sync error: \(err)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section(header: Text("Paired Devices in Account (\(cloudService.registeredDevices.count))").font(.headline)) {
                if cloudService.registeredDevices.isEmpty {
                    Text(cloudService.currentUser == nil ? "Sign in to see paired devices." : "No other devices detected yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(cloudService.registeredDevices) { dev in
                        HStack {
                            Image(systemName: dev.deviceType == "macos" ? "desktopcomputer" : "iphone")
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading) {
                                Text(dev.deviceName)
                                    .font(.body)
                                Text("\(dev.deviceId) • \(dev.deviceType.uppercased())")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(dev.status.capitalized)
                                .font(.caption)
                                .foregroundColor(dev.status == "online" ? .green : .secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helper Methods
    private func fetchLocalWiFiIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        return address
    }
}

private extension Color {
    func toHex() -> String? {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Float(components.redComponent)
        let g = Float(components.greenComponent)
        let b = Float(components.blueComponent)
        return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
    }
}
