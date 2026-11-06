using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using AmbientDisplay.Core;
using AmbientDisplay.Core.Display;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace AmbientDisplay.App.UI.Overlay;

/// <summary>
/// Canvas surface. Billboard/sunrise show a headline; image and video render full-bleed behind it;
/// web dashboards fill the area between the status bars. Port of macOS <c>CanvasOverlayView.swift</c>.
/// </summary>
public partial class CanvasView : IDisposable
{
    private static readonly SolidColorBrush TitleBrush = OverlayStyle.Brush(OverlayStyle.Rgb(0.92, 0.92, 0.95));
    private static readonly SolidColorBrush SubtitleBrush = OverlayStyle.Brush(OverlayStyle.Rgb(0.65, 0.65, 0.7));

    private readonly ActiveCanvas _canvas;
    private readonly Action _onDismiss;
    private readonly Func<DateTimeOffset> _now;
    private readonly DispatcherTimer? _countdownTimer;
    private MediaElement? _video;
    private WebView2? _webView;
    private bool _disposed;

    public CanvasView(ActiveCanvas canvas, string screenName, Action onDismiss, Func<DateTimeOffset> now, bool loadMedia = true)
    {
        _canvas = canvas;
        _onDismiss = onDismiss;
        _now = now;
        InitializeComponent();

        var phoneOnly = canvas.DismissPolicy == DismissPolicy.PhoneOnly;
        var accent = phoneOnly ? OverlayStyle.Rgb(1.0, 0.4, 0.3) : OverlayStyle.Rgb(0.4, 0.7, 1.0);

        // ---- Header
        TypeIcon.Text = IconFor(canvas);
        TypeIcon.Foreground = OverlayStyle.Brush(accent);
        HeaderTitle.Text = HeaderFor(canvas);
        HeaderTitle.Foreground = OverlayStyle.Brush(OverlayStyle.Rgb(0.6, 0.6, 0.65));
        HeaderSeparator.Foreground = OverlayStyle.Brush(OverlayStyle.Rgb(0.4, 0.4, 0.45));
        HeaderDetail.Foreground = OverlayStyle.Brush(OverlayStyle.Rgb(0.5, 0.5, 0.55));
        HeaderDetail.Text = canvas.Type == CanvasPayloadType.Webview ? $"{canvas.Title}  •  {screenName}" : screenName;

        LockedBadge.Visibility = phoneOnly ? Visibility.Visible : Visibility.Collapsed;
        LockedBadge.Background = OverlayStyle.Brush(OverlayStyle.Rgb(0.3, 0.1, 0.1), 0.85);
        LockIcon.Text = OverlayStyle.GlyphLock;
        TextElement.SetForeground(LockedBadge, OverlayStyle.Brush(OverlayStyle.Rgb(1.0, 0.35, 0.35)));

        TimerBadge.Background = OverlayStyle.Brush(OverlayStyle.Rgb(0.25, 0.2, 0.1), 0.8);
        TimerIcon.Text = OverlayStyle.GlyphTimer;
        TextElement.SetForeground(TimerBadge, OverlayStyle.Brush(OverlayStyle.Rgb(1.0, 0.75, 0.3)));

        TimeText.Text = canvas.CreatedAt.ToLocalTime().ToString("t", CultureInfo.CurrentCulture);
        TimeText.Foreground = OverlayStyle.Brush(OverlayStyle.Rgb(0.6, 0.6, 0.65));

        // ---- Centre text
        var fontSize = TitleFontSize(canvas.Title);
        TitleText.Text = canvas.Title;
        TitleText.FontSize = fontSize;
        TitleText.LineHeight = fontSize * 1.2 + 10;
        TitleText.Foreground = TitleBrush;
        SubtitleText.Text = canvas.Subtitle ?? string.Empty;
        SubtitleText.Visibility = string.IsNullOrEmpty(canvas.Subtitle) ? Visibility.Collapsed : Visibility.Visible;
        SubtitleText.FontSize = Math.Max(18, fontSize * 0.45);
        SubtitleText.Foreground = SubtitleBrush;

        // ---- Footer
        DismissButton.Visibility = phoneOnly ? Visibility.Collapsed : Visibility.Visible;
        DismissButton.Background = OverlayStyle.Gray(0.15);
        DismissText.Foreground = OverlayStyle.Brush(OverlayStyle.Rgb(0.75, 0.75, 0.8));
        PhoneOnlyHint.Visibility = phoneOnly ? Visibility.Visible : Visibility.Collapsed;
        PhoneIcon.Text = OverlayStyle.GlyphPhone;
        TextElement.SetForeground(PhoneOnlyHint, OverlayStyle.Gray(0.45));
        HintText.Visibility = phoneOnly ? Visibility.Collapsed : Visibility.Visible;
        HintText.Foreground = OverlayStyle.Gray(0.4);

        // ---- Media
        if (loadMedia)
        {
            LoadMedia();
        }

        UpdateCountdown();
        if (canvas.ExpiresAt is not null)
        {
            _countdownTimer = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => UpdateCountdown(), Dispatcher);
            _countdownTimer.Start();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _countdownTimer?.Stop();

        if (_video is not null)
        {
            _video.MediaEnded -= OnVideoEnded;
            _video.Stop();
            _video.Close();
            _video = null;
        }

        _webView?.Dispose();
        _webView = null;
        MediaLayer.Children.Clear();
    }

    internal static double TitleFontSize(string title) => title.Length switch
    {
        <= 25 => 80,
        <= 70 => 56,
        <= 160 => 38,
        _ => 28,
    };

    private void OnDismissClicked(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        _onDismiss();
    }

    private void UpdateCountdown()
    {
        var remaining = _canvas.RemainingSeconds(_now());
        if (remaining is > 0)
        {
            TimerBadge.Visibility = Visibility.Visible;
            TimerText.Text = $"Closes in {remaining}s";
        }
        else
        {
            TimerBadge.Visibility = Visibility.Collapsed;
        }
    }

    private void LoadMedia()
    {
        var uri = SafeMediaUri(_canvas.MediaUrl);
        switch (_canvas.Type)
        {
            case CanvasPayloadType.Image when uri is not null:
                ShowImage(uri);
                ShowVignette(0.6, 0.3, 0.7);
                break;
            case CanvasPayloadType.Video when uri is not null:
                ShowVideo(uri);
                ShowVignette(0.5, 0.0, 0.6);
                break;
            case CanvasPayloadType.Webview when uri is not null:
                TextPanel.Visibility = Visibility.Collapsed;
                WebHost.Visibility = Visibility.Visible;
                _ = ShowWebAsync(uri);
                break;
            case CanvasPayloadType.Image or CanvasPayloadType.Video or CanvasPayloadType.Webview:
                Log.Info("CanvasView", $"Ignoring missing or non-http(s) media URL '{_canvas.MediaUrl}'.");
                break;
        }
    }

    private void ShowImage(Uri uri)
    {
        var status = MediaStatus("Loading ambient image…", OverlayStyle.GlyphPhoto);
        MediaLayer.Children.Add(status);

        var bitmap = new BitmapImage();
        bitmap.BeginInit();
        bitmap.UriSource = uri;
        bitmap.CacheOption = BitmapCacheOption.OnLoad;
        bitmap.EndInit();

        var image = new Image { Source = bitmap, Stretch = Stretch.UniformToFill, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        MediaLayer.Children.Insert(0, image);

        void Failed(object? sender, ExceptionEventArgs e)
        {
            Log.Info("CanvasView", $"Image failed to load from {uri}: {e.ErrorException?.Message}");
            MediaLayer.Children.Remove(status);
            MediaLayer.Children.Add(MediaStatus("Unable to load ambient image", OverlayStyle.GlyphWarning));
        }

        if (bitmap.IsDownloading)
        {
            bitmap.DownloadCompleted += (_, _) => MediaLayer.Children.Remove(status);
            bitmap.DownloadFailed += Failed;
            bitmap.DecodeFailed += Failed;
        }
        else
        {
            MediaLayer.Children.Remove(status);
        }
    }

    private void ShowVideo(Uri uri)
    {
        _video = new MediaElement
        {
            Source = uri,
            LoadedBehavior = MediaState.Manual,
            UnloadedBehavior = MediaState.Close,
            IsMuted = true,
            Stretch = Stretch.UniformToFill,
        };
        _video.MediaEnded += OnVideoEnded;
        _video.MediaFailed += (_, e) =>
        {
            Log.Info("CanvasView", $"Video failed to play from {uri}: {e.ErrorException?.Message}");
            MediaLayer.Children.Add(MediaStatus("Unable to play ambient video", OverlayStyle.GlyphWarning));
        };
        MediaLayer.Children.Add(_video);
        _video.Play();
    }

    private void OnVideoEnded(object sender, RoutedEventArgs e)
    {
        // Seamless loop (AVPlayerLooper equivalent).
        if (_video is null)
        {
            return;
        }

        _video.Position = TimeSpan.Zero;
        _video.Play();
    }

    private async Task ShowWebAsync(Uri uri)
    {
        var webView = new WebView2 { DefaultBackgroundColor = System.Drawing.Color.Black };
        _webView = webView;
        WebHost.Child = webView;
        try
        {
            var environment = await WebViewEnvironment.GetAsync();
            if (_disposed)
            {
                return;
            }

            await webView.EnsureCoreWebView2Async(environment);
            if (_disposed)
            {
                return;
            }

            webView.CoreWebView2.Settings.AreDevToolsEnabled = false;
            webView.CoreWebView2.Settings.IsStatusBarEnabled = false;
            webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
            webView.CoreWebView2.NewWindowRequested += (_, args) => args.Handled = true; // no popups
            webView.Source = uri;
        }
        catch (Exception ex) when (ex is WebView2RuntimeNotFoundException or InvalidOperationException or COMException)
        {
            Log.Info("CanvasView", $"WebView2 unavailable: {ex.Message}");
            WebHost.Child = MediaStatus("Web dashboards need the Microsoft Edge WebView2 Runtime", OverlayStyle.GlyphGlobe);
        }
    }

    private void ShowVignette(double top, double middle, double bottom)
    {
        var gradient = new LinearGradientBrush { StartPoint = new Point(0.5, 0), EndPoint = new Point(0.5, 1) };
        gradient.GradientStops.Add(new GradientStop(Color.FromArgb((byte)(top * 255), 0, 0, 0), 0));
        gradient.GradientStops.Add(new GradientStop(Color.FromArgb((byte)(middle * 255), 0, 0, 0), 0.5));
        gradient.GradientStops.Add(new GradientStop(Color.FromArgb((byte)(bottom * 255), 0, 0, 0), 1));
        gradient.Freeze();
        Vignette.Fill = gradient;
        Vignette.Visibility = Visibility.Visible;
    }

    private static FrameworkElement MediaStatus(string message, string glyph)
    {
        var panel = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(new TextBlock
        {
            Text = glyph,
            FontFamily = (FontFamily)Application.Current.FindResource("IconFont"),
            FontSize = 40,
            Foreground = OverlayStyle.Gray(0.55),
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        panel.Children.Add(new TextBlock
        {
            Text = message,
            Margin = new Thickness(0, 12, 0, 0),
            FontFamily = (FontFamily)Application.Current.FindResource("DisplayFont"),
            FontSize = 14,
            Foreground = OverlayStyle.Gray(0.55),
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        return new Grid { Background = Brushes.Black, Children = { panel } };
    }

    /// <summary>Only http(s) media is loaded; file:// and other schemes are refused.</summary>
    internal static Uri? SafeMediaUri(string? raw) =>
        Uri.TryCreate(raw?.Trim(), UriKind.Absolute, out var uri) && (uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeHttp)
            ? uri
            : null;

    private static string IconFor(ActiveCanvas canvas) => canvas.Type switch
    {
        CanvasPayloadType.Billboard => canvas.DismissPolicy == DismissPolicy.PhoneOnly ? OverlayStyle.GlyphShield : OverlayStyle.GlyphMessage,
        CanvasPayloadType.Sunrise => OverlayStyle.GlyphSun,
        CanvasPayloadType.Image => OverlayStyle.GlyphPhoto,
        CanvasPayloadType.Video => OverlayStyle.GlyphVideo,
        CanvasPayloadType.Webview => OverlayStyle.GlyphGlobe,
        _ => OverlayStyle.GlyphMessage,
    };

    private static string HeaderFor(ActiveCanvas canvas) => canvas.Type switch
    {
        CanvasPayloadType.Billboard => canvas.DismissPolicy == DismissPolicy.PhoneOnly ? "AMBIENT DISPLAY • LOCKED" : "AMBIENT DISPLAY",
        CanvasPayloadType.Sunrise => "SUNRISE ROUTINE",
        CanvasPayloadType.Image => "AMBIENT POSTER",
        CanvasPayloadType.Video => "AMBIENT MOTION",
        CanvasPayloadType.Webview => "AMBIENT DASHBOARD",
        _ => "AMBIENT DISPLAY",
    };
}

/// <summary>One WebView2 environment per process, with its profile under %LOCALAPPDATA% (not beside the exe).</summary>
internal static class WebViewEnvironment
{
    private static Task<CoreWebView2Environment>? _environment;

    public static Task<CoreWebView2Environment> GetAsync() => _environment ??= CreateAsync();

    private static Task<CoreWebView2Environment> CreateAsync()
    {
        var userData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AmbientDisplay", "WebView2");
        var options = new CoreWebView2EnvironmentOptions("--autoplay-policy=no-user-gesture-required");
        return CoreWebView2Environment.CreateAsync(browserExecutableFolder: null, userDataFolder: userData, options: options);
    }
}
