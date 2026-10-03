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

    public static let deepNight = AmbientTheme(
        textPrimary: Color(red: 0.85, green: 0.35, blue: 0.15), // Warm, low-luminescence amber/ember
        textSecondary: Color(red: 0.55, green: 0.25, blue: 0.10),
        accent: Color(red: 0.90, green: 0.40, blue: 0.15),
        background: Color.black,
        opacity: 0.65,
        isNightMode: true
    )

    public static let dawn = AmbientTheme(
        textPrimary: Color(red: 1.0, green: 0.75, blue: 0.40), // Warm gold sunrise
        textSecondary: Color(red: 0.80, green: 0.60, blue: 0.35),
        accent: Color(red: 1.0, green: 0.65, blue: 0.20),
        background: Color.black,
        opacity: 0.85,
        isNightMode: false
    )

    public static let morningReady = AmbientTheme(
        textPrimary: Color(red: 0.25, green: 0.90, blue: 0.55), // Bright friendly emerald/mint "Wake me up"
        textSecondary: Color(red: 0.85, green: 0.95, blue: 0.90),
        accent: Color(red: 0.30, green: 1.0, blue: 0.60),
        background: Color.black,
        opacity: 1.0,
        isNightMode: false
    )
}

public final class SolarCalculator {
    public static func currentTheme(session: SleepSession?, state: SessionState, date: Date = Date()) -> AmbientTheme {
        if state == .wakeUpReady {
            return .morningReady
        }

        guard let session = session else {
            return .deepNight
        }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)

        // If target wake time is within 30 minutes or hour >= 6 AM, transition into dawn/morning
        let remainingSeconds = session.timeRemaining(at: date)
        if remainingSeconds <= 1800 || (hour >= 6 && hour < 10) {
            return .dawn
        }

        return .deepNight
    }
}
