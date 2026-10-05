import SwiftUI

@MainActor
public struct AmbientDisplayView: View {
    @ObservedObject var appState: AppState
    let screenName: String

    public init(appState: AppState, screenName: String = "Display") {
        self.appState = appState
        self.screenName = screenName
    }

    public var body: some View {
        let theme = SolarCalculator.currentTheme(
            session: appState.currentSession,
            state: appState.state,
            date: appState.lastUpdated,
            appState: appState
        )

        ZStack {
            // Pitch black background for zero backlight bleed in dark hall
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 28) {
                // Top ambient bar
                HStack {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 10, height: 10)
                        Text(topStatusText)
                            .font(.system(size: 18, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.textSecondary)
                    }

                    Spacer()

                    Text(currentClockTimeString)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                }
                .padding(.horizontal, 48)
                .padding(.top, 36)

                Spacer()

                // Center Main Content
                if appState.state == .wakeUpReady {
                    wakeUpReadyView(theme: theme)
                } else if let session = appState.currentSession {
                    sleepingCountdownView(session: session, theme: theme)
                } else {
                    idlePlaceholderView(theme: theme)
                }

                Spacer()

                // Bottom informative footer
                HStack {
                    if let session = appState.currentSession {
                        let durHours = session.durationMinutes / 60.0
                        let durString = String(format: durHours.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", durHours)
                        Text("Fell asleep: \(session.formattedBedtime)  •  Target: \(session.formattedTargetTime) (\(durString)h)")
                            .font(.system(size: 18, weight: .regular, design: .rounded))
                            .foregroundColor(theme.textSecondary.opacity(0.8))
                    }

                    Spacer()

                    Text("Press ESC or tap anywhere to dismiss")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(theme.textSecondary.opacity(0.5))
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 36)
            }
            .opacity(theme.opacity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture {
            if appState.state == .wakeUpReady {
                appState.dismissWakeUp()
            } else if appState.state == .sleeping {
                appState.stopSleep()
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func wakeUpReadyView(theme: AmbientTheme) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 96))
                .foregroundColor(theme.accent)
                .shadow(color: theme.accent.opacity(0.4), radius: 25)

            Text("WAKE ME UP")
                .font(.system(size: 88, weight: .black, design: .rounded))
                .foregroundColor(theme.textPrimary)
                .shadow(color: theme.accent.opacity(0.5), radius: 20)

            let durationHours = (appState.currentSession?.durationMinutes ?? (appState.defaultSleepHours * 60.0)) / 60.0
            let durationString = String(format: durationHours.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", durationHours)
            Text("\(durationString) hours of sleep completed. You are ready to wake up!")
                .font(.system(size: 32, weight: .medium, design: .rounded))
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)

            Button(action: {
                appState.dismissWakeUp()
            }) {
                Text("Dismiss Alarm")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(theme.accent.opacity(0.2))
                    .foregroundColor(theme.textPrimary)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.accent, lineWidth: 1.5)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 16)
        }
    }

    @ViewBuilder
    private func sleepingCountdownView(session: SleepSession, theme: AmbientTheme) -> some View {
        VStack(spacing: 16) {
            Text("TARGET WAKE UP TIME")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .tracking(3)
                .foregroundColor(theme.textSecondary)

            // Giant, unmistakable wake time readable across the entire hall
            Text(session.formattedTargetTime)
                .font(.system(size: 130, weight: .heavy, design: .rounded))
                .foregroundColor(theme.textPrimary)
                .shadow(color: theme.accent.opacity(0.35), radius: 24)

            // Dynamic countdown: minute-based over the night, seconds in last 5 minutes
            HStack(spacing: 12) {
                if session.isFinalFiveMinutes(at: appState.lastUpdated) {
                    Image(systemName: "timer")
                        .font(.system(size: 32))
                        .foregroundColor(theme.accent)
                }

                Text(session.formattedCountdown(at: appState.lastUpdated))
                    .font(.system(
                        size: session.isFinalFiveMinutes(at: appState.lastUpdated) ? 60 : 42,
                        weight: .semibold,
                        design: .monospaced
                    ))
                    .foregroundColor(session.isFinalFiveMinutes(at: appState.lastUpdated) ? theme.accent : theme.textSecondary)
            }
            .padding(.top, 12)

            Text("Please do not wake before \(session.formattedTargetTime)")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundColor(theme.textSecondary.opacity(0.85))
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func idlePlaceholderView(theme: AmbientTheme) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "bed.double.fill")
                .font(.system(size: 64))
                .foregroundColor(theme.textSecondary)

            Text("Wake Me Up is Idle")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(theme.textPrimary)

            Text("Waiting for sleep trigger from Android phone...")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(theme.textSecondary)
        }
    }

    private var topStatusText: String {
        switch appState.state {
        case .wakeUpReady:
            return "WAKE UP TIME"
        case .sleeping:
            return appState.isTestMode ? "SIMULATION MODE (PREVIEW)" : "SLEEPING — DO NOT DISTURB"
        case .idle:
            return "STANDBY"
        }
    }

    private var currentClockTimeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: appState.lastUpdated)
    }
}
