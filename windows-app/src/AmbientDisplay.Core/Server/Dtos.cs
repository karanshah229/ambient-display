using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AmbientDisplay.Core.Server;

// Wire contract of the LAN API. Property names serialize as snake_case via ApiJson.Options,
// matching macOS DTOs.swift field-for-field. Null optionals are omitted (Swift encodeIfPresent).

public sealed class SleepRequestPayload
{
    public double? BedtimeEpochMs { get; init; }
    public double? DurationMinutes { get; init; }
    public string? Reason { get; init; }
}

public sealed class TestRequestPayload
{
    public int? DurationSeconds { get; init; }
}

public sealed class AwayRequestPayload
{
    public bool? IsAwayMode { get; init; }
}

public sealed record StatusResponsePayload(
    string State,
    bool IsAwayMode,
    bool IsTestMode,
    string? Bedtime,
    string? TargetWakeTime,
    double? RemainingSeconds,
    string? CountdownText,
    int ScreensCount,
    bool PowerAssertionActive);

public sealed record ConfigResponsePayload(
    double DefaultSleepHours,
    int SleepWindowStartHour,
    int SleepWindowEndHour,
    int AutoPushWindowStartHour,
    int AutoPushWindowEndHour,
    double InactivityOffsetMinutes,
    bool AutoDetectInactivity,
    bool IsAwayMode,
    string? AmbientNightColorHex,
    string? AmbientDawnColorHex,
    string? AmbientWakeColorHex);

public sealed class ConfigUpdateRequestPayload
{
    public double? DefaultSleepHours { get; init; }
    public int? SleepWindowStartHour { get; init; }
    public int? SleepWindowEndHour { get; init; }
    public int? AutoPushWindowStartHour { get; init; }
    public int? AutoPushWindowEndHour { get; init; }
    public double? InactivityOffsetMinutes { get; init; }
    public bool? AutoDetectInactivity { get; init; }
    public bool? IsAwayMode { get; init; }
    public string? AmbientNightColorHex { get; init; }
    public string? AmbientDawnColorHex { get; init; }
    public string? AmbientWakeColorHex { get; init; }
}

public sealed record DisplayInfoDto(
    string Id,
    string Name,
    bool IsMain,
    int Width,
    int Height,
    string ActiveMode, // "idle" | "sleeping" | "message"
    bool IsIgnored);

public sealed record DisplaysResponsePayload(IReadOnlyList<DisplayInfoDto> Displays);

public sealed class PostMessageRequestPayload
{
    public required string Text { get; init; }
    public string? TargetDisplayId { get; init; } // "all" or a specific display ID
    public int? DurationSeconds { get; init; }    // null or 0 = persistent
}

public sealed class DismissRequestPayload
{
    public string? TargetDisplayId { get; init; }
}

public sealed record ActiveMessageDto(
    string Id,
    string Text,
    string TargetDisplayId,
    int? DurationSeconds,
    string CreatedAt,
    int? RemainingSeconds);

public sealed record MessageStatusResponsePayload(IReadOnlyList<ActiveMessageDto> ActiveMessages);

public sealed record CanvasPayloadDto(
    string Id,
    string Type,
    string? Title,
    string? Subtitle,
    string? MediaUrl,
    string? Theme,
    string DismissPolicy,
    string TargetDisplayId,
    int? DurationSeconds,
    string CreatedAt,
    int? RemainingSeconds);

public sealed class PostCanvasRequestPayload
{
    public string? Type { get; init; }           // defaults to "billboard"
    public string? Title { get; init; }
    public string? Subtitle { get; init; }
    public string? Text { get; init; }           // backward-compatible alias for title
    public string? MediaUrl { get; init; }
    public string? Theme { get; init; }
    public string? DismissPolicy { get; init; }  // "esc_any" (default) or "phone_only"
    public string? TargetDisplayId { get; init; }
    public int? DurationSeconds { get; init; }
}

public sealed record CanvasStatusResponsePayload(IReadOnlyList<CanvasPayloadDto> ActiveCanvases);

/// <summary>Cloud fleet entry. Serialized with camelCase keys, like the macOS CloudDeviceDTO.</summary>
public sealed record CloudDeviceDto(
    [property: JsonPropertyName("deviceId")] string DeviceId,
    [property: JsonPropertyName("deviceName")] string DeviceName,
    [property: JsonPropertyName("deviceType")] string DeviceType,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("lastSeen")] string? LastSeen,
    [property: JsonPropertyName("activeCanvas")] IReadOnlyDictionary<string, string>? ActiveCanvas);

public static class ApiJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
        RespectNullableAnnotations = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>Like Swift's <c>try? JSONDecoder().decode</c>: any failure (empty body, bad JSON, wrong types) yields null.</summary>
    public static T? TryDeserialize<T>(ReadOnlySpan<byte> body)
        where T : class
    {
        if (body.IsEmpty)
        {
            return null;
        }

        try
        {
            return JsonSerializer.Deserialize<T>(body, Options);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Options);

    /// <summary>ISO-8601 in UTC without fractional seconds (Swift ISO8601DateFormatter default).</summary>
    public static string Iso8601(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    /// <summary>Formats a double the way Swift string interpolation does (450 -> "450.0").</summary>
    public static string SwiftDouble(double value)
    {
        var text = value.ToString("R", CultureInfo.InvariantCulture);
        return text.Contains('.') || text.Contains('E') || text.Contains("Infinity") || text == "NaN" ? text : text + ".0";
    }

    /// <summary>JSON string-escapes a value for hand-built JSON bodies (without surrounding quotes).</summary>
    public static string Escape(string value)
    {
        var quoted = JsonSerializer.Serialize(value, Options);
        return quoted[1..^1];
    }
}
