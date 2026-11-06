namespace AmbientDisplay.Core.Display;

/// <summary>A connected monitor. <see cref="Id"/> must be stable across reboots and reconnects.</summary>
public sealed record DisplayInfo(string Id, string Name, bool IsPrimary, int Width, int Height);

/// <summary>Enumerates connected monitors. <see cref="DisplaysChanged"/> must be raised on the UI thread.</summary>
public interface IDisplayProvider
{
    IReadOnlyList<DisplayInfo> GetDisplays();

    event EventHandler? DisplaysChanged;
}

/// <summary>
/// Renders full-screen surfaces. The coordinator decides what each display shows; the presenter owns windows.
/// All calls happen on the UI thread.
/// </summary>
public interface ISurfacePresenter
{
    /// <summary>Show (or refresh) the ambient sleep countdown / wake-up surface on a display.</summary>
    void ShowAmbient(DisplayInfo display);

    void ShowCanvas(DisplayInfo display, ActiveCanvas canvas);

    void Hide(string displayId);

    void HideAll();

    /// <summary>Bring overlay windows to the foreground (macOS: NSApp.activate).</summary>
    void BringToFront();

    /// <summary>Audible feedback when a local dismissal is rejected (phone_only canvases).</summary>
    void SignalRejected();
}

/// <summary>Keeps the system and displays awake while a surface is visible.</summary>
public interface IPowerManager
{
    bool IsAsserted { get; }

    /// <summary>Wakes displays and acquires display + system "required" requests (idempotent).</summary>
    void Acquire(string reason = "Ambient Display Active Sleep Countdown");

    void Release();

    void WakeDisplays();
}

/// <summary>Marshals work onto the UI thread from server/background threads.</summary>
public interface IUiDispatcher
{
    Task<T> InvokeAsync<T>(Func<T> func);

    Task InvokeAsync(Action action);
}

/// <summary>Runs work inline on the calling thread. Used by tests and headless hosts.</summary>
public sealed class InlineDispatcher : IUiDispatcher
{
    public Task<T> InvokeAsync<T>(Func<T> func) => Task.FromResult(func());

    public Task InvokeAsync(Action action)
    {
        action();
        return Task.CompletedTask;
    }
}
