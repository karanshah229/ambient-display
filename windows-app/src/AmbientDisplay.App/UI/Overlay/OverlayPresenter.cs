using System.Media;
using AmbientDisplay.App.Platform;
using AmbientDisplay.Core;
using AmbientDisplay.Core.Display;
using AmbientDisplay.Core.State;
using static AmbientDisplay.App.Platform.NativeMethods;

namespace AmbientDisplay.App.UI.Overlay;

/// <summary>
/// Owns one <see cref="OverlayWindow"/> per covered monitor and renders what the
/// <see cref="DisplayCoordinator"/> asks for. Local input (ESC, clicks, Alt+F4) is routed back to the coordinator.
/// </summary>
internal sealed class OverlayPresenter : ISurfacePresenter, IDisposable
{
    private readonly AppState _app;
    private readonly IDisplayProvider _displays;
    private readonly Func<IReadOnlyDictionary<string, RECT>> _monitorBounds;
    private readonly Dictionary<string, OverlayWindow> _windows = new(StringComparer.OrdinalIgnoreCase);
    private readonly GlobalEscapeHotkey _escapeHotkey;
    private DisplayCoordinator? _coordinator;

    public OverlayPresenter(AppState app, IDisplayProvider displays, Func<IReadOnlyDictionary<string, RECT>> monitorBounds)
    {
        _app = app;
        _displays = displays;
        _monitorBounds = monitorBounds;
        _escapeHotkey = new GlobalEscapeHotkey(OnGlobalEscape);
    }

    /// <summary>Connects input handling. The coordinator is created after the presenter (it needs it).</summary>
    public void Attach(DisplayCoordinator coordinator) => _coordinator = coordinator;

    public void ShowAmbient(DisplayInfo display)
    {
        var window = GetOrCreateWindow(display);
        if (window is null)
        {
            return;
        }

        if (window.Content is not AmbientView)
        {
            window.SetContent(new AmbientView(_app, () => HandleClick(display.Id), () => DateTimeOffset.Now));
        }

        ShowWindow(window);
    }

    public void ShowCanvas(DisplayInfo display, ActiveCanvas canvas)
    {
        var window = GetOrCreateWindow(display);
        if (window is null)
        {
            return;
        }

        window.SetContent(new CanvasView(canvas, display.Name, () => HandleClick(display.Id), () => _app.Now));
        ShowWindow(window);
    }

    public void Hide(string displayId)
    {
        if (_windows.Remove(displayId, out var window))
        {
            window.CloseForReal();
        }

        UpdateEscapeHotkey();
    }

    public void HideAll()
    {
        foreach (var window in _windows.Values)
        {
            window.CloseForReal();
        }

        _windows.Clear();
        UpdateEscapeHotkey();
    }

    public void BringToFront()
    {
        if (_windows.Count == 0)
        {
            return;
        }

        var focusTarget = WindowUnderCursor() ?? _windows.Values.First();
        foreach (var window in _windows.Values.Where(w => !ReferenceEquals(w, focusTarget)))
        {
            window.RaiseToTop(activate: false);
        }

        // Activate last so the focused overlay ends up on top and receives ESC.
        focusTarget.RaiseToTop(activate: true);
    }

    public void SignalRejected() => SystemSounds.Beep.Play();

    public void Dispose()
    {
        HideAll();
        _escapeHotkey.Dispose();
    }

    private OverlayWindow? GetOrCreateWindow(DisplayInfo display)
    {
        var bounds = _monitorBounds();
        if (!bounds.TryGetValue(display.Id, out var rect))
        {
            Log.Info("Overlay", $"No monitor bounds for display {display.Id}; skipping.");
            return null;
        }

        if (_windows.TryGetValue(display.Id, out var existing))
        {
            existing.UpdateBounds(rect);
            return existing;
        }

        var window = new OverlayWindow(display.Id, rect);
        window.EscapePressed += (_, _) => _coordinator?.HandleEscape(display.Id);
        window.BackgroundClicked += (_, _) => HandleClick(display.Id);
        window.CloseRequested += (_, _) => _coordinator?.HandleEscape(display.Id);
        _windows[display.Id] = window;
        return window;
    }

    private void ShowWindow(OverlayWindow window)
    {
        if (!window.IsVisible)
        {
            window.Show();
        }

        UpdateEscapeHotkey();
    }

    private void HandleClick(string displayId)
    {
        if (_coordinator?.HandleClick(displayId) == LocalDismissOutcome.Rejected)
        {
            SignalRejected();
        }
    }

    private void OnGlobalEscape()
    {
        var target = WindowUnderCursor() ?? _windows.Values.FirstOrDefault();
        if (target is not null)
        {
            _coordinator?.HandleEscape(target.DisplayId);
        }
    }

    /// <summary>Global ESC only while every monitor is covered, so typing on an uncovered monitor is never hijacked.</summary>
    private void UpdateEscapeHotkey()
    {
        var all = _displays.GetDisplays();
        var everyMonitorCovered = all.Count > 0 && all.All(d => _windows.TryGetValue(d.Id, out var w) && w.IsVisible);
        _escapeHotkey.SetEnabled(everyMonitorCovered);
    }

    private OverlayWindow? WindowUnderCursor()
    {
        if (!GetCursorPos(out var point))
        {
            return null;
        }

        foreach (var (displayId, rect) in _monitorBounds())
        {
            if (point.X >= rect.Left && point.X < rect.Right && point.Y >= rect.Top && point.Y < rect.Bottom
                && _windows.TryGetValue(displayId, out var window))
            {
                return window;
            }
        }

        return null;
    }
}
