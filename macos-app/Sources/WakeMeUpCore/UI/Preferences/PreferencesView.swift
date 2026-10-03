import SwiftUI
import AppKit

@MainActor
public struct PreferencesView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var launchAtLogin = LaunchAtLoginManager.shared

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

            networkTab
                .tabItem {
                    Label("Network", systemImage: "network")
                }
        }
        .frame(width: 500, height: 420)
        .padding(20)
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
            Section(header: Text("Default Target Duration").font(.headline)) {
                Picker("Sleep Duration", selection: $appState.defaultSleepMinutes) {
                    Text("6.0 Hours (4 Sleep Cycles)").tag(360.0)
                    Text("7.5 Hours (5 Cycles — Recommended)").tag(450.0)
                    Text("9.0 Hours (6 Sleep Cycles)").tag(540.0)
                }
                .pickerStyle(.radioGroup)

                Text("Human sleep consists of ~90-minute ultradian cycles. 7.5 hours corresponds to 5 complete cycles for optimal alertness.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("OnePlus Inactivity Buffer").font(.headline)) {
                HStack {
                    Image(systemName: "timer")
                        .foregroundColor(.orange)
                    Text("Automatic 30-Minute Offset")
                        .fontWeight(.medium)
                }
                Text("When the companion app detects display sleep, it automatically subtracts the phone display timeout (30 min) to compensate for falling asleep mid-movie.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Displays Tab
    private var displaysTab: some View {
        Form {
            Section(header: Text("Detected Displays (\(NSScreen.screens.count))").font(.headline)) {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                    HStack {
                        Image(systemName: "display")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(screen.localizedName)
                                .fontWeight(.semibold)
                            Text("\(Int(screen.frame.width)) × \(Int(screen.frame.height)) pt")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text(index == 0 ? "Main Monitor" : "Mirrored Display")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(6)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(header: Text("Ambient Presentation").font(.headline)) {
                HStack {
                    Circle().fill(Color.black).frame(width: 14, height: 14).overlay(Circle().stroke(Color.gray, lineWidth: 1))
                    Text("Zero Backlight Bleed (Pitch Black #000000)")
                        .font(.caption)
                }
                HStack {
                    Circle().fill(Color.orange).frame(width: 14, height: 14)
                    Text("Deep Night Amber (Ultra-low luminescence overnight)")
                        .font(.caption)
                }
                HStack {
                    Circle().fill(Color.green).frame(width: 14, height: 14)
                    Text("Emerald Wake-Up Banner (High contrast at morning)")
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Network Tab
    private var networkTab: some View {
        Form {
            Section(header: Text("Local Server Configuration").font(.headline)) {
                LabeledContent("HTTP Port", value: "8321")
                LabeledContent("Bonjour mDNS Service", value: "_wakemeup._tcp (WakeMeUpMac)")

                Text("Listens on all local interfaces (0.0.0.0:8321) for Android sleep events.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Companion App Connection").font(.headline)) {
                Text("Your Android phone automatically discovers this Mac via Bonjour DNS-SD. If using manual setup, use your Mac's Wi-Fi IP address.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Trigger 10s Display Preview") {
                    AppState.shared.startTestMode(durationSeconds: 10)
                }
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }
}
