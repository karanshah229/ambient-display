using System.Globalization;
using AmbientDisplay.Core.Models;

namespace AmbientDisplay.Core.Display;

public enum AmbientPhase
{
    Night,
    Dawn,
    Wake,
}

/// <summary>
/// Accent colour and dimming for the ambient surface. Everything renders over pure black.
/// Text uses <see cref="AccentHex"/>; secondary text uses the accent at <see cref="SecondaryOpacity"/>;
/// the whole layout is drawn at <see cref="Opacity"/>.
/// </summary>
public sealed record AmbientTheme(AmbientPhase Phase, string AccentHex, double Opacity, double SecondaryOpacity)
{
    public bool IsNightMode => Phase == AmbientPhase.Night;
}

/// <summary>Port of macOS <c>SolarCalculator.swift</c>.</summary>
public static class SolarCalculator
{
    public static AmbientTheme CurrentTheme(
        SleepSession? session,
        SessionState state,
        DateTimeOffset now,
        string? nightColorHex,
        string? dawnColorHex,
        string? wakeColorHex)
    {
        var night = NormalizeHex(nightColorHex, "#D95926");
        var dawn = NormalizeHex(dawnColorHex, "#FA7268");
        var wake = NormalizeHex(wakeColorHex, "#FFD000");

        if (state == SessionState.WakeUpReady)
        {
            return new AmbientTheme(AmbientPhase.Wake, wake, 1.0, 0.85);
        }

        if (session is null)
        {
            return new AmbientTheme(AmbientPhase.Night, night, 0.65, 0.75);
        }

        // Within 30 minutes of the target, or between 6 and 10 AM local time, shift into dawn.
        var hour = now.ToLocalTime().Hour;
        if (session.TimeRemainingSeconds(now) <= 1800 || (hour >= 6 && hour < 10))
        {
            return new AmbientTheme(AmbientPhase.Dawn, dawn, 0.85, 0.85);
        }

        return new AmbientTheme(AmbientPhase.Night, night, 0.65, 0.75);
    }

    /// <summary>Returns "#RRGGBB" for a valid 6-digit hex (with or without '#'), otherwise the fallback.</summary>
    public static string NormalizeHex(string? hex, string fallback)
    {
        if (string.IsNullOrWhiteSpace(hex))
        {
            return fallback;
        }

        var clean = hex.Trim().TrimStart('#');
        return clean.Length == 6 && int.TryParse(clean, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out _)
            ? "#" + clean.ToUpperInvariant()
            : fallback;
    }
}
