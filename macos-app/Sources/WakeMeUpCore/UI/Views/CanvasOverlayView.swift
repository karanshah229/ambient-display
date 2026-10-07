import SwiftUI

/// Unified Ambient Surface Canvas View that renders different payload types:
/// - Billboard: headline text, optional subtitle, status header, time
/// - Sunrise: circadian sunrise countdown & gradient (delegates to AmbientDisplayView)
/// - Image: remote image rendering (prepared for Phase 2)
/// - Video: video loop (prepared for Phase 2)
/// - Webview: dashboard (prepared for Phase 2)
@MainActor
public struct CanvasOverlayView: View {
    public let canvas: ActiveCanvas
    public let screenName: String
    public let onDismiss: () -> Void

    @State private var remainingSeconds: Int?

    public init(
        canvas: ActiveCanvas,
        screenName: String,
        onDismiss: @escaping () -> Void
    ) {
        self.canvas = canvas
        self.screenName = screenName
        self.onDismiss = onDismiss
        self._remainingSeconds = State(initialValue: canvas.durationSeconds)
    }

    private var fontSize: CGFloat {
        let count = canvas.title.count
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
        return formatter.string(from: canvas.createdAt)
    }

    public var body: some View {
        ZStack {
            // Pure black background for true OLED / deep contrast
            Color.black
                .ignoresSafeArea()

            // Background Media Layer (for image, video, webview)
            if let mediaUrlStr = canvas.mediaUrl, let mediaUrl = URL(string: mediaUrlStr) {
                switch canvas.type {
                case .image:
                    RemoteAmbientImageView(url: mediaUrl)
                        .ignoresSafeArea()
                    // Subtle vignette overlay so text overlay remains readable if provided
                    LinearGradient(
                        colors: [Color.black.opacity(0.6), Color.black.opacity(0.3), Color.black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                case .video:
                    LoopingVideoPlayerView(url: mediaUrl)
                        .ignoresSafeArea()
                    LinearGradient(
                        colors: [Color.black.opacity(0.5), Color.clear, Color.black.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                case .webview:
                    AmbientWebView(url: mediaUrl)
                        .ignoresSafeArea()
                default:
                    EmptyView()
                }
            }

            VStack(spacing: 24) {
                // Top status bar
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: iconName)
                            .font(.system(size: 16))
                            .foregroundColor(statusAccentColor)
                        Text(headerTitle)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.65))
                        Text("•")
                            .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.45))
                        Text(screenName)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.55))
                    }

                    Spacer()

                    // Phone-only padlock badge if dismiss_policy == phone_only
                    if canvas.dismissPolicy == .phoneOnly {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 12))
                            Text("LOCKED")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(Color(red: 1.0, green: 0.35, blue: 0.35))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.3, green: 0.1, blue: 0.1).opacity(0.85))
                        .cornerRadius(6)
                    }

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

                // Center Content (Title & Subtitle if not a standalone webview)
                if canvas.type != .webview || !canvas.title.isEmpty {
                    VStack(spacing: 16) {
                        if !canvas.title.isEmpty {
                            Text(canvas.title)
                                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                                .foregroundColor(Color(red: 0.92, green: 0.92, blue: 0.95))
                                .multilineTextAlignment(.center)
                                .lineSpacing(10)
                                .padding(.horizontal, 64)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let subtitle = canvas.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: max(18, fontSize * 0.45), weight: .regular, design: .rounded))
                                .foregroundColor(Color(red: 0.65, green: 0.65, blue: 0.7))
                                .multilineTextAlignment(.center)
                                .lineSpacing(6)
                                .padding(.horizontal, 80)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Spacer()

                // Bottom footer with dismissal hint
                HStack {
                    if canvas.dismissPolicy == .phoneOnly {
                        HStack(spacing: 8) {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .font(.system(size: 14))
                            Text("Dismiss from Ambient Surface on your phone")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(Color(white: 0.45))
                    } else {
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
                    }

                    Spacer()

                    if canvas.dismissPolicy != .phoneOnly {
                        Text("Press ESC or tap anywhere to dismiss")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(Color(white: 0.4))
                    }
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 36)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            if canvas.dismissPolicy != .phoneOnly {
                onDismiss()
            }
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

    private var iconName: String {
        switch canvas.type {
        case .billboard:
            return canvas.dismissPolicy == .phoneOnly ? "lock.shield.fill" : "message.fill"
        case .sunrise:
            return "sun.max.fill"
        case .image:
            return "photo.fill"
        case .video:
            return "play.rectangle.fill"
        case .webview:
            return "globe"
        }
    }

    private var headerTitle: String {
        switch canvas.type {
        case .billboard:
            return canvas.dismissPolicy == .phoneOnly ? "AMBIENT SURFACE • LOCKED" : "AMBIENT SURFACE"
        case .sunrise:
            return "SUNRISE ROUTINE"
        case .image:
            return "AMBIENT POSTER"
        case .video:
            return "AMBIENT MOTION"
        case .webview:
            return "AMBIENT DASHBOARD"
        }
    }

    private var statusAccentColor: Color {
        if canvas.dismissPolicy == .phoneOnly {
            return Color(red: 1.0, green: 0.4, blue: 0.3)
        }
        return Color(red: 0.4, green: 0.7, blue: 1.0)
    }
}
