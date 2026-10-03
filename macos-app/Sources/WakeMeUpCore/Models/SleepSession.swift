import Foundation

public struct SleepSession: Codable, Equatable, Identifiable {
    public let id: UUID
    public let bedtime: Date
    public let targetWakeTime: Date
    public let durationMinutes: Double
    public let reason: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        bedtime: Date,
        durationMinutes: Double = 450.0, // 7.5 hours default (5 x 90-minute sleep cycles)
        reason: String = "auto",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bedtime = bedtime
        self.durationMinutes = durationMinutes
        self.targetWakeTime = bedtime.addingTimeInterval(durationMinutes * 60.0)
        self.reason = reason
        self.createdAt = createdAt
    }

    public init(
        id: UUID = UUID(),
        bedtime: Date,
        targetWakeTime: Date,
        reason: String = "manual",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bedtime = bedtime
        self.targetWakeTime = targetWakeTime
        self.durationMinutes = max(0, targetWakeTime.timeIntervalSince(bedtime) / 60.0)
        self.reason = reason
        self.createdAt = createdAt
    }

    /// Remaining time in seconds. Clamped to >= 0.
    public func timeRemaining(at date: Date = Date()) -> TimeInterval {
        max(0, targetWakeTime.timeIntervalSince(date))
    }

    /// Returns true when target wake time has been reached or passed.
    public func isExpired(at date: Date = Date()) -> Bool {
        date >= targetWakeTime
    }

    /// Returns true when remaining time is less than or equal to 5 minutes (300 seconds).
    public func isFinalFiveMinutes(at date: Date = Date()) -> Bool {
        let remaining = timeRemaining(at: date)
        return remaining > 0 && remaining <= 300
    }

    /// Formatted string for the countdown display.
    /// Over 5 minutes remaining: updates on minute basis ("7h 30m remaining" or "42m remaining")
    /// Final 5 minutes: updates on second basis ("04:59")
    public func formattedCountdown(at date: Date = Date()) -> String {
        let remaining = timeRemaining(at: date)
        if remaining <= 0 {
            return "00:00"
        }

        if isFinalFiveMinutes(at: date) {
            let minutes = Int(remaining) / 60
            let seconds = Int(remaining) % 60
            return String(format: "%02d:%02d", minutes, seconds)
        } else {
            let totalMinutes = Int(ceil(remaining / 60.0))
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            if hours > 0 {
                return "\(hours)h \(mins)m remaining"
            } else {
                return "\(mins)m remaining"
            }
        }
    }

    public var formattedTargetTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: targetWakeTime)
    }

    public var formattedBedtime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: bedtime)
    }

    public func elapsedMinutes(at date: Date = Date()) -> Int {
        max(0, Int(date.timeIntervalSince(bedtime) / 60.0))
    }
}
