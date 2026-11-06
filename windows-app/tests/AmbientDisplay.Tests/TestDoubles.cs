using AmbientDisplay.Core.Cloud;
using AmbientDisplay.Core.Display;
using AmbientDisplay.Core.Server;
using AmbientDisplay.Core.Settings;
using AmbientDisplay.Core.State;

namespace AmbientDisplay.Tests;

internal sealed class ManualTimeProvider(DateTimeOffset start) : TimeProvider
{
    private DateTimeOffset _now = start;

    public override DateTimeOffset GetUtcNow() => _now;

    public void Advance(TimeSpan by) => _now += by;
}

internal sealed class FakeDisplayProvider : IDisplayProvider
{
    public List<DisplayInfo> Displays { get; } =
    [
        new("aaaa0001", "DELL P2722HE", IsPrimary: true, Width: 1920, Height: 1080),
        new("bbbb0002", "Built-in Display", IsPrimary: false, Width: 2560, Height: 1600),
    ];

    public event EventHandler? DisplaysChanged;

    public IReadOnlyList<DisplayInfo> GetDisplays() => Displays;

    public void RaiseChanged() => DisplaysChanged?.Invoke(this, EventArgs.Empty);
}

internal sealed class RecordingPresenter : ISurfacePresenter
{
    public Dictionary<string, string> Visible { get; } = new(StringComparer.OrdinalIgnoreCase);

    public int RejectedSignals { get; private set; }

    public void ShowAmbient(DisplayInfo display) => Visible[display.Id] = "ambient";

    public void ShowCanvas(DisplayInfo display, ActiveCanvas canvas) => Visible[display.Id] = $"canvas:{canvas.Title}";

    public void Hide(string displayId) => Visible.Remove(displayId);

    public void HideAll() => Visible.Clear();

    public void BringToFront()
    {
    }

    public void SignalRejected() => RejectedSignals++;
}

internal sealed class FakePowerManager : IPowerManager
{
    public bool IsAsserted { get; private set; }

    public int WakeCount { get; private set; }

    public void Acquire(string reason = "test")
    {
        WakeDisplays();
        IsAsserted = true;
    }

    public void Release() => IsAsserted = false;

    public void WakeDisplays() => WakeCount++;
}

/// <summary>Wires Core together with fakes, like the WPF composition root does with real services.</summary>
internal sealed class TestHost
{
    public TestHost(ISettingsStore? store = null)
    {
        Time = new ManualTimeProvider(new DateTimeOffset(2026, 11, 6, 22, 0, 0, TimeSpan.Zero));
        Store = store ?? JsonSettingsStore.InMemory();
        App = new AppState(Store, Time);
        Coordinator = new DisplayCoordinator(App, Displays, Presenter, Power);
        Cloud = new DisabledCloudService(new DeviceIdentity(Store, "Karan's Desktop PC"));
        Router = new ApiRouter(new InlineDispatcher(), App, Coordinator, Power, Cloud, () => PreferencesOpened++);
    }

    public ManualTimeProvider Time { get; }
    public ISettingsStore Store { get; }
    public AppState App { get; }
    public FakeDisplayProvider Displays { get; } = new();
    public RecordingPresenter Presenter { get; } = new();
    public FakePowerManager Power { get; } = new();
    public DisplayCoordinator Coordinator { get; }
    public DisabledCloudService Cloud { get; }
    public ApiRouter Router { get; }
    public int PreferencesOpened { get; private set; }

    public string ModeOf(int index) =>
        Coordinator.GetConnectedDisplays()[index].ActiveMode;
}
