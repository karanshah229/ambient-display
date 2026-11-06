using System.Globalization;
using AmbientDisplay.Core.Display;

namespace AmbientDisplay.Core.Cloud;

/// <summary>
/// A canvas delivered through Firestore (<c>users/{uid}/devices/{deviceId}.activeCanvas</c>).
/// The Android app writes snake_case keys; the Firestore rules also allow camelCase, so both are read.
/// </summary>
public sealed record CloudCanvas(
    CanvasPayloadType Type,
    string Title,
    string? Subtitle,
    string? MediaUrl,
    string? Theme,
    DismissPolicy DismissPolicy,
    string TargetDisplayId,
    int? DurationSeconds,
    string Fingerprint)
{
    /// <summary>
    /// Parses an <c>activeCanvas</c> map. Returns null for a missing, empty or contentless map (no title, type or
    /// media), which means "nothing should be showing". Port of handleActiveCanvas in FirebaseCloudService.swift.
    /// </summary>
    public static CloudCanvas? Parse(IReadOnlyDictionary<string, object?>? map)
    {
        if (map is null || map.Count == 0)
        {
            return null;
        }

        var typeRaw = Str(map, "type");
        var title = Str(map, "title");
        var mediaUrl = NullIfEmpty(Str(map, "mediaUrl") ?? Str(map, "media_url"));
        if (string.IsNullOrWhiteSpace(title) && typeRaw is null && mediaUrl is null)
        {
            return null;
        }

        var subtitle = NullIfEmpty(Str(map, "subtitle")?.Trim());
        var theme = NullIfEmpty(Str(map, "theme"));
        var policyRaw = Str(map, "dismissPolicy") ?? Str(map, "dismiss_policy");
        var target = NullIfEmpty(Str(map, "targetDisplayId") ?? Str(map, "target_display_id")) ?? "all";
        var duration = Int(map, "durationSeconds") ?? Int(map, "duration_seconds");
        var created = map.TryGetValue("created_at", out var c) ? c : map.GetValueOrDefault("createdAt");
        var resolvedTitle = string.IsNullOrWhiteSpace(title) ? "Ambient Display" : title.Trim();

        // Identity of this delivery. created_at (set by the phone on every send) lets an identical message be re-sent.
        var fingerprint = string.Join('|', typeRaw, resolvedTitle, subtitle, mediaUrl, policyRaw, target, duration, Convert.ToString(created, CultureInfo.InvariantCulture));

        return new CloudCanvas(
            CanvasWire.ParseType(typeRaw),
            resolvedTitle,
            subtitle,
            mediaUrl,
            theme,
            CanvasWire.ParsePolicy(policyRaw),
            target,
            duration is > 0 ? duration : null,
            fingerprint);
    }

    private static string? Str(IReadOnlyDictionary<string, object?> map, string key) =>
        map.TryGetValue(key, out var value) && value is string s ? s : null;

    private static string? NullIfEmpty(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;

    private static int? Int(IReadOnlyDictionary<string, object?> map, string key) => map.TryGetValue(key, out var value)
        ? value switch
        {
            int i => i,
            long l => (int)Math.Clamp(l, int.MinValue, int.MaxValue),
            double d => (int)d,
            string s when int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) => parsed,
            _ => null,
        }
        : null;
}
