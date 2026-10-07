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

public struct ConfigResponsePayload: Codable {
    public let default_sleep_hours: Double
    public let sleep_window_start_hour: Int
    public let sleep_window_end_hour: Int
    public let auto_push_window_start_hour: Int
    public let auto_push_window_end_hour: Int
    public let inactivity_offset_minutes: Double
    public let auto_detect_inactivity: Bool
    public let is_away_mode: Bool

    public init(
        default_sleep_hours: Double,
        sleep_window_start_hour: Int,
        sleep_window_end_hour: Int,
        auto_push_window_start_hour: Int,
        auto_push_window_end_hour: Int,
        inactivity_offset_minutes: Double,
        auto_detect_inactivity: Bool,
        is_away_mode: Bool
    ) {
        self.default_sleep_hours = default_sleep_hours
        self.sleep_window_start_hour = sleep_window_start_hour
        self.sleep_window_end_hour = sleep_window_end_hour
        self.auto_push_window_start_hour = auto_push_window_start_hour
        self.auto_push_window_end_hour = auto_push_window_end_hour
        self.inactivity_offset_minutes = inactivity_offset_minutes
        self.auto_detect_inactivity = auto_detect_inactivity
        self.is_away_mode = is_away_mode
    }
}

public struct ConfigUpdateRequestPayload: Codable {
    public let default_sleep_hours: Double?
    public let sleep_window_start_hour: Int?
    public let sleep_window_end_hour: Int?
    public let auto_push_window_start_hour: Int?
    public let auto_push_window_end_hour: Int?
    public let inactivity_offset_minutes: Double?
    public let auto_detect_inactivity: Bool?
    public let is_away_mode: Bool?

    public init(
        default_sleep_hours: Double? = nil,
        sleep_window_start_hour: Int? = nil,
        sleep_window_end_hour: Int? = nil,
        auto_push_window_start_hour: Int? = nil,
        auto_push_window_end_hour: Int? = nil,
        inactivity_offset_minutes: Double? = nil,
        auto_detect_inactivity: Bool? = nil,
        is_away_mode: Bool? = nil
    ) {
        self.default_sleep_hours = default_sleep_hours
        self.sleep_window_start_hour = sleep_window_start_hour
        self.sleep_window_end_hour = sleep_window_end_hour
        self.auto_push_window_start_hour = auto_push_window_start_hour
        self.auto_push_window_end_hour = auto_push_window_end_hour
        self.inactivity_offset_minutes = inactivity_offset_minutes
        self.auto_detect_inactivity = auto_detect_inactivity
        self.is_away_mode = is_away_mode
    }
}

public struct DisplayInfoDTO: Codable {
    public let id: String
    public let name: String
    public let is_main: Bool
    public let width: Int
    public let height: Int
    public let active_mode: String // "idle", "sleeping", "message"
    public let is_ignored: Bool

    public init(
        id: String,
        name: String,
        is_main: Bool,
        width: Int,
        height: Int,
        active_mode: String,
        is_ignored: Bool
    ) {
        self.id = id
        self.name = name
        self.is_main = is_main
        self.width = width
        self.height = height
        self.active_mode = active_mode
        self.is_ignored = is_ignored
    }
}

public struct DisplaysResponsePayload: Codable {
    public let displays: [DisplayInfoDTO]

    public init(displays: [DisplayInfoDTO]) {
        self.displays = displays
    }
}

public struct PostMessageRequestPayload: Codable {
    public let text: String
    public let target_display_id: String? // "all" or specific display ID
    public let duration_seconds: Int? // nil or 0 = persistent

    public init(text: String, target_display_id: String? = "all", duration_seconds: Int? = nil) {
        self.text = text
        self.target_display_id = target_display_id
        self.duration_seconds = duration_seconds
    }
}

public struct DismissMessageRequestPayload: Codable {
    public let target_display_id: String? // "all" or specific display ID

    public init(target_display_id: String? = "all") {
        self.target_display_id = target_display_id
    }
}

public struct ActiveMessageDTO: Codable {
    public let id: String
    public let text: String
    public let target_display_id: String
    public let duration_seconds: Int?
    public let created_at: String
    public let remaining_seconds: Int?

    public init(
        id: String,
        text: String,
        target_display_id: String,
        duration_seconds: Int?,
        created_at: String,
        remaining_seconds: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.target_display_id = target_display_id
        self.duration_seconds = duration_seconds
        self.created_at = created_at
        self.remaining_seconds = remaining_seconds
    }
}

public struct MessageStatusResponsePayload: Codable {
    public let active_messages: [ActiveMessageDTO]

    public init(active_messages: [ActiveMessageDTO]) {
        self.active_messages = active_messages
    }
}

// MARK: - Ambient Surface Canvas DTOs

public enum CanvasPayloadType: String, Codable {
    case billboard // Text headline & message
    case sunrise   // Circadian sunrise alarm countdown & gradient
    case image     // Fullscreen image from URL
    case video     // Fullscreen video loop from URL
    case webview   // Fullscreen web view / dashboard
}

public enum DismissPolicy: String, Codable {
    case escAny = "esc_any"       // Dismiss on ESC or tap on any display
    case phoneOnly = "phone_only" // Persistent, cannot be dismissed by ESC on Mac
    case pin = "pin"               // Reserved for PIN lock
}

public struct CanvasPayloadDTO: Codable {
    public let id: String
    public let type: String
    public let title: String?
    public let subtitle: String?
    public let media_url: String?
    public let theme: String?
    public let dismiss_policy: String
    public let target_display_id: String
    public let duration_seconds: Int?
    public let created_at: String
    public let remaining_seconds: Int?

    public init(
        id: String,
        type: String,
        title: String? = nil,
        subtitle: String? = nil,
        media_url: String? = nil,
        theme: String? = nil,
        dismiss_policy: String = DismissPolicy.escAny.rawValue,
        target_display_id: String = "all",
        duration_seconds: Int? = nil,
        created_at: String,
        remaining_seconds: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.media_url = media_url
        self.theme = theme
        self.dismiss_policy = dismiss_policy
        self.target_display_id = target_display_id
        self.duration_seconds = duration_seconds
        self.created_at = created_at
        self.remaining_seconds = remaining_seconds
    }
}

public struct PostCanvasRequestPayload: Codable {
    public let type: String? // defaults to "billboard"
    public let title: String?
    public let subtitle: String?
    public let text: String? // backward-compatible alias for title
    public let media_url: String?
    public let theme: String?
    public let dismiss_policy: String? // "esc_any" (default) or "phone_only"
    public let target_display_id: String?
    public let duration_seconds: Int?

    public init(
        type: String? = "billboard",
        title: String? = nil,
        subtitle: String? = nil,
        text: String? = nil,
        media_url: String? = nil,
        theme: String? = nil,
        dismiss_policy: String? = DismissPolicy.escAny.rawValue,
        target_display_id: String? = "all",
        duration_seconds: Int? = nil
    ) {
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.text = text
        self.media_url = media_url
        self.theme = theme
        self.dismiss_policy = dismiss_policy
        self.target_display_id = target_display_id
        self.duration_seconds = duration_seconds
    }
}

public struct DismissCanvasRequestPayload: Codable {
    public let target_display_id: String?

    public init(target_display_id: String? = "all") {
        self.target_display_id = target_display_id
    }
}

public struct CanvasStatusResponsePayload: Codable {
    public let active_canvases: [CanvasPayloadDTO]

    public init(active_canvases: [CanvasPayloadDTO]) {
        self.active_canvases = active_canvases
    }
}


