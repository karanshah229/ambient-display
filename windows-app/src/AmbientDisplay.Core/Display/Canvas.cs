namespace AmbientDisplay.Core.Display;

public enum CanvasPayloadType
{
    Billboard, // Text headline & message
    Sunrise,   // Circadian sunrise alarm countdown & gradient
    Image,     // Fullscreen image from URL
    Video,     // Fullscreen video loop from URL
    Webview,   // Fullscreen web view / dashboard
}

public enum DismissPolicy
{
    EscAny,    // Dismiss on ESC or click on any display
    PhoneOnly, // Persistent; cannot be dismissed locally
    Pin,       // Reserved for PIN lock
}

public static class CanvasWire
{
    public static string ToWireValue(this CanvasPayloadType type) => type switch
    {
        CanvasPayloadType.Billboard => "billboard",
        CanvasPayloadType.Sunrise => "sunrise",
        CanvasPayloadType.Image => "image",
        CanvasPayloadType.Video => "video",
        CanvasPayloadType.Webview => "webview",
        _ => "billboard",
    };

    public static string ToWireValue(this DismissPolicy policy) => policy switch
    {
        DismissPolicy.EscAny => "esc_any",
        DismissPolicy.PhoneOnly => "phone_only",
        DismissPolicy.Pin => "pin",
        _ => "esc_any",
    };

    /// <summary>Unknown or missing types fall back to billboard; "web" is an alias for webview.</summary>
    public static CanvasPayloadType ParseType(string? raw) => raw?.Trim().ToLowerInvariant() switch
    {
        "sunrise" => CanvasPayloadType.Sunrise,
        "image" => CanvasPayloadType.Image,
        "video" => CanvasPayloadType.Video,
        "web" or "webview" => CanvasPayloadType.Webview,
        _ => CanvasPayloadType.Billboard,
    };

    /// <summary>Accepts both snake_case and the camelCase spellings permitted by the Firestore rules.</summary>
    public static DismissPolicy ParsePolicy(string? raw) => raw?.Trim() switch
    {
        "phone_only" or "phoneOnly" => DismissPolicy.PhoneOnly,
        "pin" => DismissPolicy.Pin,
        _ => DismissPolicy.EscAny,
    };
}

/// <summary>A canvas currently shown on one or more displays.</summary>
public sealed record ActiveCanvas
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public CanvasPayloadType Type { get; init; } = CanvasPayloadType.Billboard;
    public required string Title { get; init; }
    public string? Subtitle { get; init; }
    public string? MediaUrl { get; init; }
    public string? Theme { get; init; }
    public DismissPolicy DismissPolicy { get; init; } = DismissPolicy.EscAny;
    public string TargetDisplayId { get; init; } = "all";
    public int? DurationSeconds { get; init; }
    public required DateTimeOffset CreatedAt { get; init; }

    /// <summary>When the canvas auto-dismisses; null for persistent canvases (no duration or 0).</summary>
    public DateTimeOffset? ExpiresAt => DurationSeconds is > 0 ? CreatedAt + TimeSpan.FromSeconds(DurationSeconds.Value) : null;

    public int? RemainingSeconds(DateTimeOffset now) =>
        ExpiresAt is { } expires ? Math.Max(0, DurationSeconds!.Value - (int)(now - CreatedAt).TotalSeconds) : null;
}

public enum ScreenModeKind
{
    Idle,
    Sleeping,
    Canvas,
}

/// <summary>What a single display is currently showing.</summary>
public sealed record ScreenMode(ScreenModeKind Kind, ActiveCanvas? Canvas = null)
{
    public static readonly ScreenMode Idle = new(ScreenModeKind.Idle);
    public static readonly ScreenMode Sleeping = new(ScreenModeKind.Sleeping);

    public static ScreenMode ForCanvas(ActiveCanvas canvas) => new(ScreenModeKind.Canvas, canvas);
}
