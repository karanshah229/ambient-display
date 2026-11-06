using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using AmbientDisplay.Core.Display;
using AmbientDisplay.Core.Settings;
using AmbientDisplay.Core.State;

namespace AmbientDisplay.App.UI.Overlay;

/// <summary>
/// Renders overlay views to PNG without opening windows (Windows counterpart of the macOS RenderSnapshots tool).
/// Run: <c>AmbientDisplay.exe --render-snapshots &lt;output-dir&gt;</c>.
/// </summary>
internal static class SnapshotRenderer
{
    private const int Width = 1920;
    private const int Height = 1080;

    public static void RenderAll(string outputDirectory)
    {
        Directory.CreateDirectory(outputDirectory);
        var tonight = new DateTimeOffset(DateTime.Today.AddHours(23).AddMinutes(10));

        Ambient(outputDirectory, "ambient_idle", tonight, _ => { });
        Ambient(outputDirectory, "ambient_night", tonight, app => app.StartSleep(tonight, 450));
        Ambient(outputDirectory, "ambient_final_five", tonight, app => app.StartSleep(tonight - TimeSpan.FromMinutes(450) + TimeSpan.FromSeconds(245), 450));
        Ambient(outputDirectory, "ambient_dawn", tonight, app => app.StartSleep(tonight - TimeSpan.FromMinutes(430), 450));
        Ambient(outputDirectory, "ambient_wake", tonight, app =>
        {
            app.StartSleep(tonight - TimeSpan.FromMinutes(450), 450);
        });
        Ambient(outputDirectory, "ambient_test_mode", tonight, app => app.StartTestMode(10));

        Canvas(outputDirectory, "canvas_billboard_locked", tonight, new ActiveCanvas
        {
            Title = "At the Gym",
            Subtitle = "Back around 5:30 PM. Please do not touch.",
            DismissPolicy = DismissPolicy.PhoneOnly,
            DurationSeconds = 90,
            CreatedAt = tonight,
        });
        Canvas(outputDirectory, "canvas_billboard_long", tonight, new ActiveCanvas
        {
            Title = "Deep work session in progress — please message instead of tapping my shoulder. Back at 3 PM.",
            CreatedAt = tonight,
        });
        Canvas(outputDirectory, "canvas_sunrise", tonight, new ActiveCanvas
        {
            Type = CanvasPayloadType.Sunrise,
            Title = "Rise and shine",
            Subtitle = "Sunrise routine starts in 10 minutes",
            CreatedAt = tonight,
        });
    }

    private static void Ambient(string directory, string name, DateTimeOffset now, Action<AppState> arrange)
    {
        var app = new AppState(JsonSettingsStore.InMemory(), new FixedTimeProvider(now));
        arrange(app);
        using var view = new AmbientView(app, () => { }, () => now, liveClock: false);
        Save(view, Path.Combine(directory, name + ".png"));
    }

    private static void Canvas(string directory, string name, DateTimeOffset now, ActiveCanvas canvas)
    {
        using var view = new CanvasView(canvas, "DELL P2722HE", () => { }, () => now.AddSeconds(5), loadMedia: false);
        Save(view, Path.Combine(directory, name + ".png"));
    }

    private static void Save(FrameworkElement view, string path)
    {
        view.Measure(new Size(Width, Height));
        view.Arrange(new Rect(0, 0, Width, Height));
        view.UpdateLayout();

        var bitmap = new RenderTargetBitmap(Width, Height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(view);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }

    private sealed class FixedTimeProvider(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now.ToUniversalTime();
    }
}
