using AmbientDisplay.Core.Models;
using AmbientDisplay.Core.Server;
using AmbientDisplay.Core.State;

namespace AmbientDisplay.Core.Display;

public enum LocalDismissOutcome
{
    /// <summary>The surface was dismissed.</summary>
    Dismissed,

    /// <summary>The canvas is locked (phone_only); the presenter should give feedback.</summary>
    Rejected,

    /// <summary>Nothing to dismiss.</summary>
    Ignored,
}

/// <summary>
/// Decides what every display shows: idle desktop, the ambient sleep countdown, or a canvas.
/// Platform-neutral port of the logic in macOS <c>WindowManager.swift</c>; rendering is delegated
/// to <see cref="ISurfacePresenter"/>. UI-thread affine.
/// </summary>
public sealed class DisplayCoordinator
{
    private const string AllTargets = "all";

    private readonly AppState _app;
    private readonly IDisplayProvider _displays;
    private readonly ISurfacePresenter _presenter;
    private readonly IPowerManager _power;
    private readonly Dictionary<string, ScreenMode> _modes = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<Guid, ActiveCanvas> _canvases = new();

    public DisplayCoordinator(AppState app, IDisplayProvider displays, ISurfacePresenter presenter, IPowerManager power)
    {
        _app = app;
        _displays = displays;
        _presenter = presenter;
        _power = power;

        _app.StateChanged += (_, state) => HandleStateChanged(state);
        _displays.DisplaysChanged += (_, _) => HandleDisplaysChanged();
    }

    /// <summary>Raised when a canvas is dismissed (locally, remotely, or on expiry). Arg: normalized target.</summary>
    public event EventHandler<string>? CanvasDismissed;

    public int DisplayCount => _displays.GetDisplays().Count;

    public bool HasActiveCanvases => _canvases.Count > 0;

    public ScreenMode CurrentMode(string displayId) => _modes.GetValueOrDefault(displayId) ?? ScreenMode.Idle;

    // ---------------------------------------------------------------- Queries (API payloads)

    public IReadOnlyList<DisplayInfoDto> GetConnectedDisplays() =>
        _displays.GetDisplays()
            .Select(d => new DisplayInfoDto(
                Id: d.Id,
                Name: d.Name,
                IsMain: d.IsPrimary,
                Width: d.Width,
                Height: d.Height,
                ActiveMode: CurrentMode(d.Id).Kind switch
                {
                    ScreenModeKind.Sleeping => "sleeping",
                    ScreenModeKind.Canvas => "message",
                    _ => "idle",
                },
                IsIgnored: _app.IsDisplayIgnored(d.Id)))
            .ToList();

    public IReadOnlyList<CanvasPayloadDto> GetActiveCanvasesList()
    {
        var now = _app.Now;
        return OrderedCanvases().Select(c => ToDto(c, c.RemainingSeconds(now))).ToList();
    }

    public IReadOnlyList<ActiveMessageDto> GetActiveMessagesList()
    {
        var now = _app.Now;
        return OrderedCanvases()
            .Select(c => new ActiveMessageDto(
                Id: c.Id.ToString().ToUpperInvariant(),
                Text: c.Subtitle is not null ? $"{c.Title} - {c.Subtitle}" : c.Title,
                TargetDisplayId: c.TargetDisplayId,
                DurationSeconds: c.DurationSeconds,
                CreatedAt: ApiJson.Iso8601(c.CreatedAt),
                RemainingSeconds: c.RemainingSeconds(now)))
            .ToList();
    }

    // ---------------------------------------------------------------- Canvases

    public CanvasPayloadDto ShowCanvas(
        CanvasPayloadType type,
        string title,
        string? subtitle = null,
        string? mediaUrl = null,
        string? theme = null,
        DismissPolicy dismissPolicy = DismissPolicy.EscAny,
        string? targetDisplayId = AllTargets,
        int? durationSeconds = null)
    {
        var target = NormalizeTarget(targetDisplayId);
        var canvas = new ActiveCanvas
        {
            Type = type,
            Title = title,
            Subtitle = subtitle,
            MediaUrl = mediaUrl,
            Theme = theme,
            DismissPolicy = dismissPolicy,
            TargetDisplayId = target,
            DurationSeconds = durationSeconds,
            CreatedAt = _app.Now,
        };

        var all = _displays.GetDisplays();
        var eligible = all.Where(d => !_app.IsDisplayIgnored(d.Id)).ToList();
        List<DisplayInfo> screens;

        if (target == AllTargets)
        {
            // Broadcasting replaces every previous canvas.
            screens = eligible;
            _canvases.Clear();
            foreach (var display in all.Where(d => !screens.Contains(d) && CurrentMode(d.Id).Kind == ScreenModeKind.Canvas))
            {
                RevertScreen(display);
            }
        }
        else
        {
            var matched = all.Where(d => string.Equals(d.Id, target, StringComparison.OrdinalIgnoreCase)).ToList();
            screens = matched.Count > 0 ? matched : eligible;
        }

        var displaced = screens
            .Select(d => CurrentMode(d.Id).Canvas?.Id)
            .OfType<Guid>()
            .ToList();

        _canvases[canvas.Id] = canvas;
        Log.Info("DisplayCoordinator", $"Displaying canvas [{type.ToWireValue()}] '{title}' on {screens.Count} screen(s) (target: {target}, policy: {dismissPolicy.ToWireValue()}, duration: {durationSeconds?.ToString() ?? "persistent"})");

        foreach (var display in screens)
        {
            _modes[display.Id] = ScreenMode.ForCanvas(canvas);
            _presenter.ShowCanvas(display, canvas);
        }

        foreach (var priorId in displaced)
        {
            RemoveCanvasIfOrphaned(priorId);
        }

        // Keep displays awake while a canvas is visible.
        _power.Acquire();
        _presenter.BringToFront();

        return ToDto(canvas, durationSeconds);
    }

    /// <summary>Legacy message API: a billboard canvas with esc_any policy.</summary>
    public ActiveMessageDto ShowMessage(string text, string? targetDisplayId = AllTargets, int? durationSeconds = null)
    {
        var dto = ShowCanvas(CanvasPayloadType.Billboard, text, targetDisplayId: targetDisplayId, durationSeconds: durationSeconds);
        return new ActiveMessageDto(dto.Id, dto.Title ?? text, dto.TargetDisplayId, dto.DurationSeconds, dto.CreatedAt, dto.RemainingSeconds);
    }

    public void DismissCanvas(string? targetDisplayId = AllTargets)
    {
        var target = NormalizeTarget(targetDisplayId);
        if (target == AllTargets)
        {
            _canvases.Clear();
            foreach (var display in _displays.GetDisplays())
            {
                if (CurrentMode(display.Id).Kind == ScreenModeKind.Canvas)
                {
                    RevertScreen(display);
                }
            }
        }
        else
        {
            var display = FindDisplay(target);
            if (display is not null)
            {
                DismissOnScreen(display);
            }
        }

        ReleasePowerIfIdle();
        CanvasDismissed?.Invoke(this, target);
    }

    public void DismissCanvasOnScreen(string displayId)
    {
        var display = FindDisplay(displayId);
        if (display is null)
        {
            return;
        }

        DismissOnScreen(display);
        ReleasePowerIfIdle();
    }

    public void DismissMessage(string? targetDisplayId = AllTargets) => DismissCanvas(targetDisplayId);

    /// <summary>True while the canvas with this API id (as returned by <see cref="ShowCanvas"/>) is still showing.</summary>
    public bool IsCanvasActive(string canvasId) =>
        Guid.TryParse(canvasId, out var id) && _canvases.ContainsKey(id);

    /// <summary>Dismisses one canvas wherever it is showing (used when the cloud withdraws it).</summary>
    public void DismissCanvasById(string canvasId)
    {
        if (!Guid.TryParse(canvasId, out var id) || !_canvases.TryGetValue(id, out var canvas))
        {
            return;
        }

        DismissCanvasById(id);
        CanvasDismissed?.Invoke(this, canvas.TargetDisplayId);
    }

    /// <summary>Called once per second by the host; expires timed canvases.</summary>
    public void Tick()
    {
        var now = _app.Now;
        var expired = _canvases.Values.Where(c => c.ExpiresAt is { } at && at <= now).ToList();
        foreach (var canvas in expired)
        {
            Log.Info("DisplayCoordinator", $"Canvas '{canvas.Title}' expired after {canvas.DurationSeconds}s.");
            DismissCanvasById(canvas.Id);
            CanvasDismissed?.Invoke(this, canvas.TargetDisplayId);
        }
    }

    // ---------------------------------------------------------------- Local input (ESC / click)

    /// <summary>ESC pressed while a surface on <paramref name="displayId"/> had focus.</summary>
    public LocalDismissOutcome HandleEscape(string displayId)
    {
        var mode = CurrentMode(displayId);
        switch (mode.Kind)
        {
            case ScreenModeKind.Canvas when mode.Canvas!.DismissPolicy == DismissPolicy.PhoneOnly:
                Log.Info("DisplayCoordinator", "ESC ignored: Canvas is locked (phone_only dismiss policy)");
                _presenter.SignalRejected();
                return LocalDismissOutcome.Rejected;

            case ScreenModeKind.Canvas:
                // ESC on any screen dismisses the canvas on every screen.
                DismissCanvas(AllTargets);
                return LocalDismissOutcome.Dismissed;

            case ScreenModeKind.Sleeping:
                // ESC on any screen dismisses the alarm / sleep session everywhere.
                _app.StopSleep();
                return LocalDismissOutcome.Dismissed;

            default:
                if (HasActiveCanvases)
                {
                    DismissCanvas(AllTargets);
                    return LocalDismissOutcome.Dismissed;
                }

                if (_app.State != SessionState.Idle)
                {
                    _app.StopSleep();
                    return LocalDismissOutcome.Dismissed;
                }

                return LocalDismissOutcome.Ignored;
        }
    }

    /// <summary>Click/tap anywhere on a surface (the explicit Dismiss buttons call this too).</summary>
    public LocalDismissOutcome HandleClick(string displayId)
    {
        var mode = CurrentMode(displayId);
        switch (mode.Kind)
        {
            case ScreenModeKind.Canvas when mode.Canvas!.DismissPolicy == DismissPolicy.PhoneOnly:
                return LocalDismissOutcome.Rejected;

            case ScreenModeKind.Canvas:
                DismissCanvas(AllTargets);
                return LocalDismissOutcome.Dismissed;

            case ScreenModeKind.Sleeping when _app.State != SessionState.Idle:
                _app.StopSleep();
                return LocalDismissOutcome.Dismissed;

            default:
                return LocalDismissOutcome.Ignored;
        }
    }

    // ---------------------------------------------------------------- Sleep surfaces

    /// <summary>Shows the ambient countdown on every eligible display that is not busy with a canvas.</summary>
    public void ShowMirroredSurfaces()
    {
        var displays = _displays.GetDisplays();
        Log.Info("DisplayCoordinator", $"Refreshing sleep displays on {displays.Count} screen(s).");

        foreach (var display in displays)
        {
            var mode = CurrentMode(display.Id);
            if (_app.IsDisplayIgnored(display.Id))
            {
                if (mode.Kind == ScreenModeKind.Sleeping)
                {
                    _modes[display.Id] = ScreenMode.Idle;
                    _presenter.Hide(display.Id);
                }

                continue;
            }

            // Mutual exclusion: never overwrite a display that is showing a canvas.
            if (mode.Kind == ScreenModeKind.Canvas)
            {
                continue;
            }

            _modes[display.Id] = ScreenMode.Sleeping;
            _presenter.ShowAmbient(display);
        }

        _presenter.BringToFront();
    }

    public void HideSleepSurfaces()
    {
        foreach (var (displayId, mode) in _modes.ToList())
        {
            if (mode.Kind == ScreenModeKind.Sleeping)
            {
                _modes[displayId] = ScreenMode.Idle;
                _presenter.Hide(displayId);
            }
        }
    }

    public void HideAll()
    {
        _canvases.Clear();
        _modes.Clear();
        _presenter.HideAll();
        _power.Release();
    }

    // ---------------------------------------------------------------- Internals

    private void HandleStateChanged(SessionState state)
    {
        switch (state)
        {
            case SessionState.Sleeping:
            case SessionState.WakeUpReady:
                _power.Acquire();
                ShowMirroredSurfaces();
                break;
            default:
                if (!HasActiveCanvases)
                {
                    _power.Release();
                }

                HideSleepSurfaces();
                break;
        }
    }

    private void HandleDisplaysChanged()
    {
        var current = _displays.GetDisplays();
        Log.Info("DisplayCoordinator", $"Screen configuration changed. Available screens: {current.Count}");

        var connected = current.Select(d => d.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var (displayId, mode) in _modes.ToList())
        {
            if (connected.Contains(displayId))
            {
                continue;
            }

            _modes.Remove(displayId);
            _presenter.Hide(displayId);
            if (mode.Canvas is { } canvas)
            {
                RemoveCanvasIfOrphaned(canvas.Id);
            }
        }

        if (_app.State != SessionState.Idle)
        {
            ShowMirroredSurfaces();
        }

        ReleasePowerIfIdle();
    }

    private void DismissOnScreen(DisplayInfo display)
    {
        var canvas = CurrentMode(display.Id).Canvas;
        RevertScreen(display);
        if (canvas is not null)
        {
            RemoveCanvasIfOrphaned(canvas.Id);
        }
    }

    private void DismissCanvasById(Guid id)
    {
        if (!_canvases.Remove(id))
        {
            return;
        }

        foreach (var display in _displays.GetDisplays())
        {
            if (CurrentMode(display.Id).Canvas?.Id == id)
            {
                RevertScreen(display);
            }
        }

        ReleasePowerIfIdle();
    }

    /// <summary>After a canvas leaves a display: back to the countdown if a session is active, else hide.</summary>
    private void RevertScreen(DisplayInfo display)
    {
        if (_app.State is SessionState.Sleeping or SessionState.WakeUpReady && !_app.IsDisplayIgnored(display.Id))
        {
            _modes[display.Id] = ScreenMode.Sleeping;
            _presenter.ShowAmbient(display);
        }
        else
        {
            _modes[display.Id] = ScreenMode.Idle;
            _presenter.Hide(display.Id);
        }
    }

    private void RemoveCanvasIfOrphaned(Guid canvasId)
    {
        if (!_modes.Values.Any(m => m.Canvas?.Id == canvasId))
        {
            _canvases.Remove(canvasId);
        }
    }

    private void ReleasePowerIfIdle()
    {
        if (!HasActiveCanvases && _app.State == SessionState.Idle)
        {
            _power.Release();
        }
    }

    private DisplayInfo? FindDisplay(string displayId) =>
        _displays.GetDisplays().FirstOrDefault(d => string.Equals(d.Id, displayId, StringComparison.OrdinalIgnoreCase));

    private IEnumerable<ActiveCanvas> OrderedCanvases() => _canvases.Values.OrderBy(c => c.CreatedAt);

    private static string NormalizeTarget(string? targetDisplayId)
    {
        var target = (targetDisplayId ?? string.Empty).Trim().ToLowerInvariant();
        return target.Length == 0 ? AllTargets : target;
    }

    private static CanvasPayloadDto ToDto(ActiveCanvas canvas, int? remainingSeconds) => new(
        Id: canvas.Id.ToString().ToUpperInvariant(),
        Type: canvas.Type.ToWireValue(),
        Title: canvas.Title,
        Subtitle: canvas.Subtitle,
        MediaUrl: canvas.MediaUrl,
        Theme: canvas.Theme,
        DismissPolicy: canvas.DismissPolicy.ToWireValue(),
        TargetDisplayId: canvas.TargetDisplayId,
        DurationSeconds: canvas.DurationSeconds,
        CreatedAt: ApiJson.Iso8601(canvas.CreatedAt),
        RemainingSeconds: remainingSeconds);
}
