using AmbientDisplay.Core;
using AmbientDisplay.Core.Display;

namespace AmbientDisplay.App.UI;

/// <summary>
/// Placeholder presenter for milestone M1: records what each display would show.
/// Replaced by the full-screen WPF overlay presenter in M2.
/// </summary>
internal sealed class LoggingSurfacePresenter : ISurfacePresenter
{
    public void ShowAmbient(DisplayInfo display) =>
        Log.Info("Presenter", $"[ambient] {display.Name} ({display.Id})");

    public void ShowCanvas(DisplayInfo display, ActiveCanvas canvas) =>
        Log.Info("Presenter", $"[canvas:{canvas.Type}] '{canvas.Title}' on {display.Name} ({display.Id})");

    public void Hide(string displayId) => Log.Info("Presenter", $"[hide] {displayId}");

    public void HideAll() => Log.Info("Presenter", "[hide all]");

    public void BringToFront()
    {
    }

    public void SignalRejected() => System.Media.SystemSounds.Beep.Play();
}
