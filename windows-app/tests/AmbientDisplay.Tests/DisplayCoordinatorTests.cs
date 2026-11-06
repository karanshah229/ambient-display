using AmbientDisplay.Core.Display;
using AmbientDisplay.Core.Models;
using AmbientDisplay.Core.Server;

namespace AmbientDisplay.Tests;

/// <summary>Port of macOS ScreenMessageTests.swift plus Windows-specific coverage of the coordinator.</summary>
public class DisplayCoordinatorTests
{
    [Fact]
    public void ShowMessageAndDismissLifecycle()
    {
        var host = new TestHost();
        var coordinator = host.Coordinator;
        Assert.False(coordinator.HasActiveCanvases);

        var dto = coordinator.ShowMessage("Hello World", "all", durationSeconds: 0);
        Assert.Equal("Hello World", dto.Text);
        Assert.Equal("all", dto.TargetDisplayId);
        Assert.True(coordinator.HasActiveCanvases);

        var list = coordinator.GetActiveMessagesList();
        Assert.Single(list);
        Assert.Equal("Hello World", list[0].Text);
        Assert.Equal("message", host.ModeOf(0));
        Assert.True(host.Power.IsAsserted);

        coordinator.DismissMessage("all");
        Assert.False(coordinator.HasActiveCanvases);
        Assert.Equal("idle", host.ModeOf(0));
        Assert.Empty(host.Presenter.Visible);
        Assert.False(host.Power.IsAsserted);
    }

    [Fact]
    public void MutualExclusionAndReversionToSleep()
    {
        var host = new TestHost();
        host.App.StartSleep(host.Time.GetUtcNow(), 450.0);
        Assert.Equal(SessionState.Sleeping, host.App.State);
        Assert.Equal("sleeping", host.ModeOf(0));

        host.Coordinator.ShowMessage("Water the plants!", "all");
        Assert.Equal("message", host.ModeOf(0));

        host.Coordinator.DismissMessage("all");
        Assert.False(host.Coordinator.HasActiveCanvases);
        Assert.Equal(SessionState.Sleeping, host.App.State);
        Assert.Equal("sleeping", host.ModeOf(0));
        Assert.Equal("ambient", host.Presenter.Visible["aaaa0001"]);
        Assert.True(host.Power.IsAsserted);

        host.App.StopSleep();
        Assert.Equal("idle", host.ModeOf(0));
        Assert.False(host.Power.IsAsserted);
    }

    [Fact]
    public void SleepDoesNotOverwriteActiveCanvas()
    {
        var host = new TestHost();
        host.Coordinator.ShowCanvas(CanvasPayloadType.Billboard, "At the Gym", targetDisplayId: "aaaa0001");

        host.App.StartSleep(host.Time.GetUtcNow(), 450.0);

        Assert.Equal("message", host.ModeOf(0));
        Assert.Equal("sleeping", host.ModeOf(1));
    }

    [Fact]
    public void UniversalDismissalDismissesOnAllScreens()
    {
        var host = new TestHost();
        host.Coordinator.ShowMessage("Important Notice", "all");
        host.Coordinator.DismissMessage("all");

        Assert.All(host.Coordinator.GetConnectedDisplays(), d => Assert.Equal("idle", d.ActiveMode));

        host.App.StartSleep(host.Time.GetUtcNow(), 450.0);
        host.App.StopSleep();

        Assert.All(host.Coordinator.GetConnectedDisplays(), d => Assert.Equal("idle", d.ActiveMode));
    }

    [Fact]
    public void CanvasShowAndDismissLifecycle()
    {
        var host = new TestHost();
        var dto = host.Coordinator.ShowCanvas(
            CanvasPayloadType.Billboard,
            "At the Gym",
            subtitle: "Back around 5:30 PM. Please do not touch.",
            theme: "midnight_ember",
            dismissPolicy: DismissPolicy.PhoneOnly);

        Assert.Equal("At the Gym", dto.Title);
        Assert.Equal("Back around 5:30 PM. Please do not touch.", dto.Subtitle);
        Assert.Equal("billboard", dto.Type);
        Assert.Equal("phone_only", dto.DismissPolicy);

        var canvases = host.Coordinator.GetActiveCanvasesList();
        Assert.Single(canvases);
        Assert.Equal("phone_only", canvases[0].DismissPolicy);

        host.Coordinator.DismissCanvas("all");
        Assert.Empty(host.Coordinator.GetActiveCanvasesList());
    }

    [Fact]
    public void ImageAndVideoCanvasPayloads()
    {
        var host = new TestHost();
        var image = host.Coordinator.ShowCanvas(CanvasPayloadType.Image, "Nature Wallpaper", "Yosemite Valley",
            "https://images.unsplash.com/photo-1426604966848-d7adac402bff", "nature", DismissPolicy.EscAny, "all", 60);
        Assert.Equal("image", image.Type);
        Assert.Equal("https://images.unsplash.com/photo-1426604966848-d7adac402bff", image.MediaUrl);

        var video = host.Coordinator.ShowCanvas(CanvasPayloadType.Video, "Rainy Cafe", "Lo-Fi Focus Stream",
            "https://example.com/loop.mp4", "rain", DismissPolicy.PhoneOnly, "all", null);
        Assert.Equal("video", video.Type);
        Assert.Equal("phone_only", video.DismissPolicy);

        // Broadcasting replaces the previous canvas.
        Assert.Single(host.Coordinator.GetActiveCanvasesList());

        host.Coordinator.DismissCanvas("all");
        Assert.False(host.Coordinator.HasActiveCanvases);
    }

    [Fact]
    public void TargetedCanvasOnlyCoversOneDisplay()
    {
        var host = new TestHost();
        var dto = host.Coordinator.ShowCanvas(CanvasPayloadType.Billboard, "Focus", targetDisplayId: " BBBB0002 ");

        Assert.Equal("bbbb0002", dto.TargetDisplayId);
        Assert.Equal("idle", host.ModeOf(0));
        Assert.Equal("message", host.ModeOf(1));
    }

    [Fact]
    public void UnknownTargetFallsBackToAllEligibleDisplays()
    {
        var host = new TestHost();
        host.App.SetDisplayIgnored("bbbb0002", ignored: true);

        host.Coordinator.ShowCanvas(CanvasPayloadType.Billboard, "Hello", targetDisplayId: "nope");

        Assert.Equal("message", host.ModeOf(0));
        Assert.Equal("idle", host.ModeOf(1));
    }

    [Fact]
    public void IgnoredDisplaysAreSkippedForSleepAndBroadcast()
    {
        var host = new TestHost();
        host.App.SetDisplayIgnored("bbbb0002", ignored: true);

        host.App.StartSleep(host.Time.GetUtcNow(), 450.0);
        Assert.Equal("sleeping", host.ModeOf(0));
        Assert.Equal("idle", host.ModeOf(1));
        Assert.True(host.Coordinator.GetConnectedDisplays()[1].IsIgnored);

        host.Coordinator.ShowCanvas(CanvasPayloadType.Billboard, "Broadcast");
        Assert.False(host.Presenter.Visible.ContainsKey("bbbb0002"));
    }

    [Fact]
    public void TimedCanvasExpiresOnTickAndNotifiesCloud()
    {
        var host = new TestHost();
        var dismissed = new List<string>();
        host.Coordinator.CanvasDismissed += (_, target) => dismissed.Add(target);
        host.Coordinator.ShowCanvas(CanvasPayloadType.Billboard, "Back in 30s", durationSeconds: 30);

        host.Time.Advance(TimeSpan.FromSeconds(12));
        host.Coordinator.Tick();
        Assert.Equal(18, host.Coordinator.GetActiveCanvasesList()[0].RemainingSeconds);

        host.Time.Advance(TimeSpan.FromSeconds(18));
        host.Coordinator.Tick();
        Assert.False(host.Coordinator.HasActiveCanvases);
        Assert.Equal(["all"], dismissed);
        Assert.False(host.Power.IsAsserted);
    }

    [Fact]
    public void EscapeRespectsPhoneOnlyPolicy()
    {
        var host = new TestHost();
        host.Coordinator.ShowCanvas(CanvasPayloadType.Billboard, "Locked", dismissPolicy: DismissPolicy.PhoneOnly);

        Assert.Equal(LocalDismissOutcome.Rejected, host.Coordinator.HandleEscape("aaaa0001"));
        Assert.Equal(LocalDismissOutcome.Rejected, host.Coordinator.HandleClick("aaaa0001"));
        Assert.Equal(1, host.Presenter.RejectedSignals);
        Assert.True(host.Coordinator.HasActiveCanvases);

        host.Coordinator.DismissCanvas("all"); // the phone can always dismiss
        Assert.False(host.Coordinator.HasActiveCanvases);
    }

    [Fact]
    public void EscapeOnOneDisplayDismissesEverywhere()
    {
        var host = new TestHost();
        host.Coordinator.ShowCanvas(CanvasPayloadType.Billboard, "Hello");

        Assert.Equal(LocalDismissOutcome.Dismissed, host.Coordinator.HandleEscape("bbbb0002"));
        Assert.All(host.Coordinator.GetConnectedDisplays(), d => Assert.Equal("idle", d.ActiveMode));

        host.App.StartSleep(host.Time.GetUtcNow(), 450.0);
        Assert.Equal(LocalDismissOutcome.Dismissed, host.Coordinator.HandleEscape("aaaa0001"));
        Assert.Equal(SessionState.Idle, host.App.State);
    }

    [Fact]
    public void ReplacingCanvasOnOneDisplayKeepsItAliveElsewhere()
    {
        var host = new TestHost();
        host.Coordinator.ShowCanvas(CanvasPayloadType.Billboard, "Everywhere");
        host.Coordinator.ShowCanvas(CanvasPayloadType.Billboard, "Just here", targetDisplayId: "aaaa0001");

        var titles = host.Coordinator.GetActiveCanvasesList().Select(c => c.Title).ToList();
        Assert.Equal(["Everywhere", "Just here"], titles);
        Assert.Equal("canvas:Everywhere", host.Presenter.Visible["bbbb0002"]);
    }

    [Fact]
    public void DisconnectedDisplayDropsItsCanvas()
    {
        var host = new TestHost();
        host.Coordinator.ShowCanvas(CanvasPayloadType.Billboard, "On laptop", targetDisplayId: "bbbb0002");

        host.Displays.Displays.RemoveAt(1);
        host.Displays.RaiseChanged();

        Assert.False(host.Coordinator.HasActiveCanvases);
        Assert.False(host.Power.IsAsserted);
    }

    [Fact]
    public void DtoKeysAreSnakeCaseLikeMacOs()
    {
        var json = ApiJson.Serialize(new DisplayInfoDto("1", "Dell", true, 1920, 1080, "idle", false));

        Assert.Contains("\"is_main\": true", json);
        Assert.Contains("\"active_mode\": \"idle\"", json);
        Assert.Contains("\"is_ignored\": false", json);
    }

    [Fact]
    public void ThemeFollowsSessionPhase()
    {
        var host = new TestHost();
        var now = host.Time.GetUtcNow();
        var session = SleepSession.FromDuration(now, 450);

        var night = SolarCalculator.CurrentTheme(session, SessionState.Sleeping, now, null, null, null);
        var dawn = SolarCalculator.CurrentTheme(session, SessionState.Sleeping, session.TargetWakeTime.AddMinutes(-20), null, null, null);
        var wake = SolarCalculator.CurrentTheme(session, SessionState.WakeUpReady, now, null, null, "#abcdef");

        Assert.Equal(AmbientPhase.Dawn, dawn.Phase);
        Assert.Equal("#FA7268", dawn.AccentHex);
        Assert.Equal("#ABCDEF", wake.AccentHex);
        Assert.Equal(1.0, wake.Opacity);
        Assert.Contains(night.Phase, new[] { AmbientPhase.Night, AmbientPhase.Dawn }); // dawn if local time is 6-10 AM
    }
}
