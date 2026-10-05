import SwiftUI

@MainActor
public struct MessageOverlayView: View {
    public let text: String
    public let screenName: String
    public let createdAt: Date
    public let durationSeconds: Int?
    public let onDismiss: () -> Void

    @State private var remainingSeconds: Int?

    public init(
        text: String,
        screenName: String,
        createdAt: Date = Date(),
        durationSeconds: Int? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.text = text
        self.screenName = screenName
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.onDismiss = onDismiss
        self._remainingSeconds = State(initialValue: durationSeconds)
    }

    private var fontSize: CGFloat {
        let count = text.count
        if count <= 25 {
            return 80
        } else if count <= 70 {
            return 56
        } else if count <= 160 {
            return 38
        } else {
            return 28
        }
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }

    public var body: some View {
        ZStack {
            // Pure true black background for zero backlight bleed
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // Top status bar
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "message.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(red: 0.4, green: 0.7, blue: 1.0))
                        Text("MESSAGE FROM PHONE")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.65))
                        Text("•")
                            .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.45))
                        Text(screenName)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.55))
                    }

                    Spacer()

                    if let remaining = remainingSeconds, remaining > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "timer")
                                .font(.system(size: 13))
                            Text("Closes in \(remaining)s")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(Color(red: 1.0, green: 0.75, blue: 0.3))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.25, green: 0.2, blue: 0.1).opacity(0.8))
                        .cornerRadius(6)
                    }

                    Text(formattedTime)
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.65))
                }
                .padding(.horizontal, 48)
                .padding(.top, 36)

                Spacer()

                // Center Message with dynamic auto-scaled typography
                VStack(spacing: 20) {
                    Text(text)
                        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                        .foregroundColor(Color(red: 0.88, green: 0.88, blue: 0.92))
                        .multilineTextAlignment(.center)
                        .lineSpacing(10)
                        .padding(.horizontal, 64)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                // Bottom footer with dismissal hint
                HStack {
                    Button(action: onDismiss) {
                        Text("Dismiss")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(red: 0.75, green: 0.75, blue: 0.8))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color(white: 0.15))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("Press ESC or tap anywhere to dismiss")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(Color(white: 0.4))
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 36)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            onDismiss()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            if let remaining = remainingSeconds {
                if remaining > 1 {
                    remainingSeconds = remaining - 1
                } else {
                    remainingSeconds = 0
                    onDismiss()
                }
            }
        }
    }
}
