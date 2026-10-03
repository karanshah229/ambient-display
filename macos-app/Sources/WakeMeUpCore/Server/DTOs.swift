import Foundation

public struct SleepRequestPayload: Codable {
    public let bedtime_epoch_ms: Double?
    public let duration_minutes: Double?
    public let reason: String?

    public init(bedtime_epoch_ms: Double? = nil, duration_minutes: Double? = nil, reason: String? = nil) {
        self.bedtime_epoch_ms = bedtime_epoch_ms
        self.duration_minutes = duration_minutes
        self.reason = reason
    }
}

public struct TestRequestPayload: Codable {
    public let duration_seconds: Int?

    public init(duration_seconds: Int? = 10) {
        self.duration_seconds = duration_seconds
    }
}

public struct AwayRequestPayload: Codable {
    public let is_away_mode: Bool?

    public init(is_away_mode: Bool? = nil) {
        self.is_away_mode = is_away_mode
    }
}

public struct StatusResponsePayload: Codable {
    public let state: String
    public let is_away_mode: Bool
    public let is_test_mode: Bool
    public let bedtime: String?
    public let target_wake_time: String?
    public let remaining_seconds: Double?
    public let countdown_text: String?
    public let screens_count: Int
    public let power_assertion_active: Bool

    public init(
        state: String,
        is_away_mode: Bool,
        is_test_mode: Bool,
        bedtime: String?,
        target_wake_time: String?,
        remaining_seconds: Double?,
        countdown_text: String?,
        screens_count: Int,
        power_assertion_active: Bool
    ) {
        self.state = state
        self.is_away_mode = is_away_mode
        self.is_test_mode = is_test_mode
        self.bedtime = bedtime
        self.target_wake_time = target_wake_time
        self.remaining_seconds = remaining_seconds
        self.countdown_text = countdown_text
        self.screens_count = screens_count
        self.power_assertion_active = power_assertion_active
    }
}
