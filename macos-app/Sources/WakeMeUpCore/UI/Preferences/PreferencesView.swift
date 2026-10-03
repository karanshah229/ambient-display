import SwiftUI
import AppKit

@MainActor
public struct PreferencesView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var launchAtLogin = LaunchAtLoginManager.shared

    @State private var sleepHoursText: String = ""
    @State private var inactivityOffsetText: String = ""
    @State private var nightColor: Color = .orange
    @State private var dawnColor: Color = .yellow
    @State private var wakeColor: Color = .green
    @State private var wifiIPAddress: String = "Detecting..."

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
        }
        .frame(width: 530, height: 460)
        .padding(20)
        .onAppear {
            loadInitialValues()
        }
    }

    private func loadInitialValues() {
        let hours = appState.defaultSleepHours
        sleepHoursText = String(format: hours.truncatingRemainder(dividingBy: 1) == 0 ? "%.1f" : "%.2g", hours)
        inactivityOffsetText = String(format: "%.0f", appState.inactivityOffsetMinutes)

        nightColor = Color(hex: appState.ambientNightColorHex, defaultFallback: AmbientTheme.defaultNightColor)
        dawnColor = Color(hex: appState.ambientDawnColorHex, defaultFallback: AmbientTheme.defaultDawnColor)
        wakeColor = Color(hex: appState.ambientWakeColorHex, defaultFallback: AmbientTheme.defaultWakeColor)

        wifiIPAddress = fetchLocalWiFiIP() ?? "Unavailable (Not connected to Wi-Fi)"
    }

    // MARK: - General Tab
    private var generalTab: some View {
        Form {
            Section(header: Text("Startup & Menu Bar").font(.headline)) {
                Toggle("Launch Wake Me Up at Login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .help("Automatically launches Wake Me Up when you log into your Mac")

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
                HStack(spacing: 10) {
                    Text("Duration:")
                    TextField("", text: $sleepHoursText)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitSleepHours() }
                    Text("hours")
                    Spacer()
                    Button("Reset to 7.5h") {
                        appState.defaultSleepHours = 7.5
                        sleepHoursText = "7.5"
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.accentColor)
                }

                Text("Default is 7.5 hours (5 × 90-minute ultradian sleep cycles). Custom duration can be any value between 1 and 16 hours.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Inactivity Compensation").font(.headline)) {
                Toggle("Auto-detect offset from phone system settings", isOn: $appState.autoDetectInactivityOffset)

                if !appState.autoDetectInactivityOffset {
                    HStack {
                        Text("Custom Inactivity Offset:")
                        TextField("Minutes", text: $inactivityOffsetText)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitOffsetMinutes() }
                        Text("minutes")
                    }
                }

                Text("Compensates for falling asleep mid-movie or while reading before the device display times out. Supported across any Android phone.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func commitSleepHours() {
        if let val = Double(sleepHoursText.trimmingCharacters(in: .whitespaces)), val >= 1.0, val <= 16.0 {
            appState.defaultSleepHours = val
        } else {
            sleepHoursText = String(format: "%.1f", appState.defaultSleepHours)
        }
    }

    private func commitOffsetMinutes() {
        if let val = Double(inactivityOffsetText.trimmingCharacters(in: .whitespaces)), val >= 0, val <= 120 {
            appState.inactivityOffsetMinutes = val
        } else {
            inactivityOffsetText = String(format: "%.0f", appState.inactivityOffsetMinutes)
        }
    }

    // MARK: - Displays Tab
    private var displaysTab: some View {
        Form {
            Section(header: Text("Detected Displays (\(NSScreen.screens.count))").font(.headline)) {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                    let screenId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                    let isIgnored = appState.ignoredDisplayIDs.contains(screenId)

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
                            appState.toggleDisplayIgnored(id: screenId)
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
                        if let hex = newColor.toHex() {
                            appState.ambientNightColorHex = hex
                        }
                    }

                ColorPicker("Dawn Warm Glow", selection: $dawnColor)
                    .onChange(of: dawnColor) { newColor in
                        if let hex = newColor.toHex() {
                            appState.ambientDawnColorHex = hex
                        }
                    }

                ColorPicker("Morning Wake-Up Glow", selection: $wakeColor)
                    .onChange(of: wakeColor) { newColor in
                        if let hex = newColor.toHex() {
                            appState.ambientWakeColorHex = hex
                        }
                    }

                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        appState.resetAmbientDefaults()
                        nightColor = Color(hex: appState.ambientNightColorHex, defaultFallback: AmbientTheme.defaultNightColor)
                        dawnColor = Color(hex: appState.ambientDawnColorHex, defaultFallback: AmbientTheme.defaultDawnColor)
                        wakeColor = Color(hex: appState.ambientWakeColorHex, defaultFallback: AmbientTheme.defaultWakeColor)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section(header: Text("Preview Notes").font(.headline)) {
                Text("All themes render over pitch black (#000000) for zero backlight bleed in dark environments.")
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
                LabeledContent("Bonjour mDNS", value: "_wakemeup._tcp (WakeMeUpMac)")

                Text("Your Android companion app connects to this Mac over your local Wi-Fi network. If DHCP assigns a new IP, Bonjour automatically updates.")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
