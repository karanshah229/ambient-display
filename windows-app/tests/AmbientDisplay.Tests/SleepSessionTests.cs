using AmbientDisplay.Core.Models;
using AmbientDisplay.Core.State;

namespace AmbientDisplay.Tests;

/// <summary>Port of macOS SleepSessionTests.swift.</summary>
public class SleepSessionTests
{
    private static readonly DateTimeOffset Epoch = DateTimeOffset.FromUnixTimeSeconds(1_000_000);

    [Fact]
    public void SleepSessionCalculates7Point5HoursCorrectly()
    {
        var session = SleepSession.FromDuration(Epoch, 450.0);

        Assert.Equal(Epoch.AddSeconds(27_000), session.TargetWakeTime);
        Assert.Equal(450.0, session.DurationMinutes);
    }

    [Fact]
    public void CountdownFormattingOverFiveMinutes()
    {
        var session = SleepSession.FromTarget(Epoch.AddSeconds(-3600), Epoch.AddSeconds(3600));

        Assert.Equal("1h 0m remaining", session.FormattedCountdown(Epoch));
    }

    [Fact]
    public void CountdownFormattingRoundsMinutesUp()
    {
        var session = SleepSession.FromTarget(Epoch.AddSeconds(-3600), Epoch.AddSeconds(42 * 60 - 30));

        Assert.Equal("42m remaining", session.FormattedCountdown(Epoch));
    }

    [Fact]
    public void CountdownFormattingFinalFiveMinutes()
    {
        var session = SleepSession.FromTarget(Epoch.AddSeconds(-10_000), Epoch.AddSeconds(245));

        Assert.True(session.IsFinalFiveMinutes(Epoch));
        Assert.Equal("04:05", session.FormattedCountdown(Epoch));
    }

    [Fact]
    public void CountdownFormattingExpired()
    {
        var session = SleepSession.FromTarget(Epoch.AddSeconds(-10_000), Epoch.AddSeconds(-10));

        Assert.True(session.IsExpired(Epoch));
        Assert.Equal("00:00", session.FormattedCountdown(Epoch));
    }

    [Fact]
    public void AppStateTransitions()
    {
        var app = new AppState(store: null);
        Assert.Equal(SessionState.Idle, app.State);

        app.StartSleep(DateTimeOffset.UtcNow, 450.0);
        Assert.Equal(SessionState.Sleeping, app.State);
        Assert.NotNull(app.CurrentSession);

        app.TriggerWakeUpReady();
        Assert.Equal(SessionState.WakeUpReady, app.State);

        app.StopSleep();
        Assert.Equal(SessionState.Idle, app.State);
        Assert.Null(app.CurrentSession);
    }

    [Fact]
    public void AwayModeIgnoresSleepEvents()
    {
        var app = new AppState(store: null) { IsAwayMode = true };

        app.StartSleep(DateTimeOffset.UtcNow, 450.0);

        Assert.Equal(SessionState.Idle, app.State);
        Assert.Null(app.CurrentSession);
    }

    [Fact]
    public void EnablingAwayModeStopsActiveSession()
    {
        var app = new AppState(store: null);
        app.StartSleep(DateTimeOffset.UtcNow, 450.0);

        app.IsAwayMode = true;

        Assert.Equal(SessionState.Idle, app.State);
    }

    [Fact]
    public void TickFiresWakeUpWhenTargetReached()
    {
        var host = new TestHost();
        host.App.StartTestMode(durationSeconds: 10);

        host.Time.Advance(TimeSpan.FromSeconds(9));
        host.App.Tick();
        Assert.Equal(SessionState.Sleeping, host.App.State);

        host.Time.Advance(TimeSpan.FromSeconds(1));
        host.App.Tick();
        Assert.Equal(SessionState.WakeUpReady, host.App.State);
    }

    [Fact]
    public void BedtimeInThePastBeyondDurationStartsWakeUpReady()
    {
        var host = new TestHost();

        host.App.StartSleep(host.Time.GetUtcNow().AddHours(-8), 450.0);

        Assert.Equal(SessionState.WakeUpReady, host.App.State);
    }
}
