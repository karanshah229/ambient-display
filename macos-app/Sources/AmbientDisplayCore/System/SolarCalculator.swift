import Foundation
import SwiftUI

/// Calculates ambient lighting factors based on time of day and sunrise approach.
public struct AmbientTheme {
    public let textPrimary: Color
    public let textSecondary: Color
    public let accent: Color
    public let background: Color
    public let opacity: Double
    public let isNightMode: Bool

    public static let defaultNightColor = Color(red: 0.85, green: 0.35, blue: 0.15) // #D95926 (Deep Night Ember)
    public static let defaultDawnColor = Color(red: 0.98, green: 0.45, blue: 0.41)  // #FA7268 (Sunrise Coral / Horizon Blush)
    public static let defaultWakeColor = Color(red: 1.0, green: 0.82, blue: 0.0)    // #FFD000 (Radiant Solar Gold / Morning Sun)

    public static let deepNight = makeNightTheme(accentColor: defaultNightColor)
    public static let dawn = makeDawnTheme(accentColor: defaultDawnColor)
    public static let morningReady = makeWakeTheme(accentColor: defaultWakeColor)

    public static func makeNightTheme(accentColor: Color) -> AmbientTheme {
        AmbientTheme(
            textPrimary: accentColor,
            textSecondary: accentColor.opacity(0.75),
            accent: accentColor,
            background: Color.black,
            opacity: 0.65,
            isNightMode: true
        )
    }

    public static func makeDawnTheme(accentColor: Color) -> AmbientTheme {
        AmbientTheme(
            textPrimary: accentColor,
            textSecondary: accentColor.opacity(0.85),
            accent: accentColor,
            background: Color.black,
            opacity: 0.85,
            isNightMode: false
        )
    }

    public static func makeWakeTheme(accentColor: Color) -> AmbientTheme {
        AmbientTheme(
            textPrimary: accentColor,
            textSecondary: accentColor.opacity(0.85),
            accent: accentColor,
            background: Color.black,
            opacity: 1.0,
            isNightMode: false
        )
    }
}

public extension Color {
    init(hex: String, defaultFallback: Color = .white) {
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        guard Scanner(string: cleanHex).scanHexInt64(&int) else {
            self = defaultFallback
            return
        }
        let r, g, b: UInt64
        switch cleanHex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            self = defaultFallback
            return
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: 1.0
        )
    }
}

@MainActor
public final class SolarCalculator {
    public static func currentTheme(session: SleepSession?, state: SessionState, date: Date = Date(), appState: AppState? = nil) -> AmbientTheme {
        let nightColor = Color(hex: appState?.ambientNightColorHex ?? "#D95926", defaultFallback: AmbientTheme.defaultNightColor)
        let dawnColor = Color(hex: appState?.ambientDawnColorHex ?? "#FA7268", defaultFallback: AmbientTheme.defaultDawnColor)
        let wakeColor = Color(hex: appState?.ambientWakeColorHex ?? "#FFD000", defaultFallback: AmbientTheme.defaultWakeColor)

        if state == .wakeUpReady {
            return AmbientTheme.makeWakeTheme(accentColor: wakeColor)
        }

        guard let session = session else {
            return AmbientTheme.makeNightTheme(accentColor: nightColor)
        }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)

        // If target wake time is within 30 minutes or hour >= 6 AM, transition into dawn/morning
        let remainingSeconds = session.timeRemaining(at: date)
        if remainingSeconds <= 1800 || (hour >= 6 && hour < 10) {
            return AmbientTheme.makeDawnTheme(accentColor: dawnColor)
        }

        return AmbientTheme.makeNightTheme(accentColor: nightColor)
    }
}
