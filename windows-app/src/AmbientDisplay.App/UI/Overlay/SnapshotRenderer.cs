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

        TrayIcons(outputDirectory);
        PreferencesTabs(outputDirectory);
    }

    private static void TrayIcons(string directory)
    {
        foreach (var state in Enum.GetValues<TrayState>())
        {
            using var icon = TrayIconArt.Create(state);
            using var bitmap = icon.ToBitmap();
            bitmap.Save(Path.Combine(directory, $"tray_{state.ToString().ToLowerInvariant()}.png"), System.Drawing.Imaging.ImageFormat.Png);
        }
    }

    private static void PreferencesTabs(string directory)
    {
        var store = JsonSettingsStore.InMemory();
        var app = new AppState(store);
        var displays = new Platform.Win32DisplayProvider(Application.Current.Dispatcher);
        var viewModel = new Preferences.PreferencesViewModel(
            app,
            new Platform.LaunchAtLoginManager(store),
            displays,
            new SnapshotCloud(),
            8321,
            () => "AmbientDisplay-PC._ambientdisplay._tcp.local");
        var window = new Preferences.PreferencesWindow(viewModel)
        {
            ShowActivated = false,
            ShowInTaskbar = false,
            WindowStartupLocation = WindowStartupLocation.Manual,
            Left = -20000,
            Top = -20000,
        };
        window.Show();

        string[] names = ["general", "sleep", "displays", "ambient", "network", "cloud"];
        for (var i = 0; i < names.Length; i++)
        {
            window.SelectedTab = i;
            window.UpdateLayout();
            window.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.Loaded);
            var content = (FrameworkElement)window.Content;
            var width = (int)Math.Ceiling(content.ActualWidth);
            var height = (int)Math.Ceiling(content.ActualHeight);

            // The Fluent window background is a system backdrop that RenderTargetBitmap can't capture, so paint it.
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
            {
                var background = window.TryFindResource("SolidBackgroundFillColorBaseBrush") as Brush
                    ?? window.TryFindResource("ApplicationBackgroundBrush") as Brush
                    ?? new SolidColorBrush(Color.FromRgb(0x20, 0x20, 0x20));
                dc.DrawRectangle(background, null, new Rect(0, 0, width, height));
                dc.DrawRectangle(new VisualBrush(content), null, new Rect(0, 0, width, height));
            }

            var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var stream = File.Create(Path.Combine(directory, $"prefs_{names[i]}.png"));
            encoder.Save(stream);
        }

        window.Close();
        displays.Dispose();
    }

    /// <summary>Signed-in cloud state with a small fleet, for the Cloud tab snapshot.</summary>
    private sealed class SnapshotCloud : Core.Cloud.ICloudService
    {
        public event EventHandler? Changed
        {
            add { }
            remove { }
        }

        public bool CanSignIn => true;

        public bool IsSigningIn => false;

        public IReadOnlyList<Core.Server.CloudDeviceDto> RegisteredDevices { get; } =
        [
            new("machine_studio_pc", "STUDIO-PC", "machine", "online", Core.Server.ApiJson.Iso8601(DateTimeOffset.UtcNow), null),
            new("machine_macbook_air", "MacBook Air", "machine", "online", "2026-11-06T16:42:12Z", null),
            new("mobile_36e021c0", "Pixel 9", "mobile", "online", Core.Server.ApiJson.Iso8601(DateTimeOffset.UtcNow.AddSeconds(-30)), null),
        ];

        public Core.Cloud.CloudStatus GetStatus() => new(
            new Core.Cloud.CloudUser("uid", "you@example.com", "You"), true, "machine_studio_pc", "STUDIO-PC", 3, null, DateTimeOffset.UtcNow);

        public Task SignInWithGoogleIdTokenAsync(string googleIdToken, CancellationToken cancellationToken) => Task.CompletedTask;

        public void StartGoogleOAuthFlow()
        {
        }

        public void SignOut()
        {
        }
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
