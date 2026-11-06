using System.Globalization;

namespace AmbientDisplay.Core.Models;

public enum SessionState
{
    Idle,
    Sleeping,
    WakeUpReady,
}

public static class SessionStateExtensions
{
    /// <summary>Wire value used by the LAN API (matches the macOS raw values).</summary>
    public static string ToWireValue(this SessionState state) => state switch
    {
        SessionState.Idle => "idle",
        SessionState.Sleeping => "sleeping",
        SessionState.WakeUpReady => "wakeUpReady",
        _ => "idle",
    };
}

/// <summary>
/// A single night's sleep session: bedtime plus a target wake time.
/// Port of macOS <c>SleepSession.swift</c>.
/// </summary>
public sealed record SleepSession
{
    /// <summary>7.5 hours = 5 x 90-minute sleep cycles.</summary>
    public const double DefaultDurationMinutes = 450.0;

    public Guid Id { get; private init; }
    public DateTimeOffset Bedtime { get; private init; }
    public DateTimeOffset TargetWakeTime { get; private init; }
    public double DurationMinutes { get; private init; }
    public string Reason { get; private init; } = "auto";
    public DateTimeOffset CreatedAt { get; private init; }

    private SleepSession()
    {
    }

    public static SleepSession FromDuration(
        DateTimeOffset bedtime,
        double durationMinutes = DefaultDurationMinutes,
        string reason = "auto",
        DateTimeOffset? createdAt = null) => new()
        {
            Id = Guid.NewGuid(),
            Bedtime = bedtime,
            DurationMinutes = durationMinutes,
            TargetWakeTime = bedtime + TimeSpan.FromMinutes(durationMinutes),
            Reason = reason,
            CreatedAt = createdAt ?? bedtime,
        };

    public static SleepSession FromTarget(
        DateTimeOffset bedtime,
        DateTimeOffset targetWakeTime,
        string reason = "manual",
        DateTimeOffset? createdAt = null) => new()
        {
            Id = Guid.NewGuid(),
            Bedtime = bedtime,
            TargetWakeTime = targetWakeTime,
            DurationMinutes = Math.Max(0, (targetWakeTime - bedtime).TotalMinutes),
            Reason = reason,
            CreatedAt = createdAt ?? bedtime,
        };

    /// <summary>Remaining time in seconds, clamped to &gt;= 0.</summary>
    public double TimeRemainingSeconds(DateTimeOffset at) => Math.Max(0, (TargetWakeTime - at).TotalSeconds);

    public bool IsExpired(DateTimeOffset at) => at >= TargetWakeTime;

    public bool IsFinalFiveMinutes(DateTimeOffset at)
    {
        var remaining = TimeRemainingSeconds(at);
        return remaining > 0 && remaining <= 300;
    }

    /// <summary>
    /// Over 5 minutes: "7h 30m remaining" / "42m remaining" (minute resolution, rounded up).
    /// Final 5 minutes: "04:59". Expired: "00:00".
    /// </summary>
    public string FormattedCountdown(DateTimeOffset at)
    {
        var remaining = TimeRemainingSeconds(at);
        if (remaining <= 0)
        {
            return "00:00";
        }

        if (IsFinalFiveMinutes(at))
        {
            var whole = (int)remaining;
            return $"{whole / 60:00}:{whole % 60:00}";
        }

        var totalMinutes = (int)Math.Ceiling(remaining / 60.0);
        var hours = totalMinutes / 60;
        var minutes = totalMinutes % 60;
        return hours > 0 ? $"{hours}h {minutes}m remaining" : $"{minutes}m remaining";
    }

    public string FormattedTargetTime(CultureInfo? culture = null) => FormatShortTime(TargetWakeTime, culture);

    public string FormattedBedtime(CultureInfo? culture = null) => FormatShortTime(Bedtime, culture);

    public int ElapsedMinutes(DateTimeOffset at) => Math.Max(0, (int)((at - Bedtime).TotalMinutes));

    public static string FormatShortTime(DateTimeOffset time, CultureInfo? culture = null) =>
        time.ToLocalTime().ToString("t", culture ?? CultureInfo.CurrentCulture);
}
