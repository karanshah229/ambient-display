using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using AmbientDisplay.Core.Display;
using AmbientDisplay.Core.Models;
using AmbientDisplay.Core.State;

namespace AmbientDisplay.App.UI.Overlay;

/// <summary>
/// Ambient sleep surface: giant target wake time and countdown over pure black, colour-shifting from
/// night ember to dawn coral to morning gold. Port of macOS <c>AmbientDisplayView.swift</c>.
/// </summary>
public partial class AmbientView : IDisposable
{
    private static readonly Color DefaultNight = Color.FromRgb(0xD9, 0x59, 0x26);

    private readonly AppState _app;
    private readonly Action _onDismiss;
    private readonly Func<DateTimeOffset> _clock;
    private readonly DispatcherTimer? _clockTimer;
    private bool _disposed;

    public AmbientView(AppState app, Action onDismiss, Func<DateTimeOffset>? clock = null, bool liveClock = true)
    {
        _app = app;
        _onDismiss = onDismiss;
        _clock = clock ?? (() => DateTimeOffset.Now);
        InitializeComponent();

        StatusDot.Fill = Brushes.Transparent;
        WakeIcon.Text = OverlayStyle.GlyphSun;
        TimerIcon.Text = OverlayStyle.GlyphTimer;
        IdleIcon.Text = OverlayStyle.GlyphMoon;

        _app.PropertyChanged += OnAppStateChanged;
        if (liveClock)
        {
            // The wall clock keeps running even after the countdown stops ticking (wake-up state).
            _clockTimer = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => UpdateClock(), Dispatcher);
            _clockTimer.Start();
        }

        Refresh();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _clockTimer?.Stop();
        _app.PropertyChanged -= OnAppStateChanged;
    }

    private void OnAppStateChanged(object? sender, PropertyChangedEventArgs e) => Refresh();

    private void OnDismissClicked(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        _onDismiss();
    }

    private void Refresh()
    {
        if (_disposed)
        {
            return;
        }

        var session = _app.CurrentSession;
        var at = _app.LastUpdated;
        var theme = SolarCalculator.CurrentTheme(session, _app.State, at,
            _app.AmbientNightColorHex, _app.AmbientDawnColorHex, _app.AmbientWakeColorHex);

        var accent = OverlayStyle.FromHex(theme.AccentHex, DefaultNight);
        var primary = OverlayStyle.Brush(accent);
        var secondary = OverlayStyle.Brush(accent, theme.SecondaryOpacity);
        Layout.Opacity = theme.Opacity;

        StatusDot.Fill = primary;
        StatusText.Foreground = secondary;
        StatusText.Text = _app.State switch
        {
            SessionState.WakeUpReady => "WAKE UP TIME",
            SessionState.Sleeping => _app.IsTestMode ? "SIMULATION MODE (PREVIEW)" : "SLEEPING — DO NOT DISTURB",
            _ => "STANDBY",
        };
        ClockText.Foreground = secondary;
        UpdateClock();

        WakePanel.Visibility = _app.State == SessionState.WakeUpReady ? Visibility.Visible : Visibility.Collapsed;
        CountdownPanel.Visibility = _app.State != SessionState.WakeUpReady && session is not null ? Visibility.Visible : Visibility.Collapsed;
        IdlePanel.Visibility = _app.State != SessionState.WakeUpReady && session is null ? Visibility.Visible : Visibility.Collapsed;

        if (WakePanel.Visibility == Visibility.Visible)
        {
            var hours = (session?.DurationMinutes ?? _app.DefaultSleepMinutes) / 60.0;
            WakeIcon.Foreground = primary;
            WakeIcon.Effect = Glow(accent, 0.4, 25);
            WakeTitle.Foreground = primary;
            WakeTitle.Effect = Glow(accent, 0.5, 20);
            WakeSubtitle.Foreground = secondary;
            WakeSubtitle.Text = $"{OverlayStyle.FormatHours(hours)} hours of sleep completed. You are ready to wake up!";
            DismissAlarmButton.Background = OverlayStyle.Brush(accent, 0.2);
            DismissAlarmButton.BorderBrush = primary;
            DismissAlarmText.Foreground = primary;
        }

        if (CountdownPanel.Visibility == Visibility.Visible && session is not null)
        {
            var finalFive = session.IsFinalFiveMinutes(at);
            TargetLabel.Foreground = secondary;
            TargetTime.Text = session.FormattedTargetTime();
            TargetTime.Foreground = primary;
            TargetTime.Effect = Glow(accent, 0.35, 24);
            TimerIcon.Visibility = finalFive ? Visibility.Visible : Visibility.Collapsed;
            TimerIcon.Foreground = primary;
            CountdownText.Text = session.FormattedCountdown(at);
            CountdownText.FontSize = finalFive ? 60 : 42;
            CountdownText.Foreground = finalFive ? primary : secondary;
            DoNotWakeText.Text = $"Please do not wake before {session.FormattedTargetTime()}";
            DoNotWakeText.Foreground = OverlayStyle.Brush(accent, theme.SecondaryOpacity * 0.85);
        }

        if (IdlePanel.Visibility == Visibility.Visible)
        {
            IdleIcon.Foreground = secondary;
            IdleTitle.Foreground = primary;
            IdleSubtitle.Foreground = secondary;
        }

        if (session is not null)
        {
            SessionText.Visibility = Visibility.Visible;
            SessionText.Text = $"Fell asleep: {session.FormattedBedtime()}  •  Target: {session.FormattedTargetTime()} ({OverlayStyle.FormatHours(session.DurationMinutes / 60.0)}h)";
            SessionText.Foreground = OverlayStyle.Brush(accent, theme.SecondaryOpacity * 0.8);
        }
        else
        {
            SessionText.Visibility = Visibility.Collapsed;
        }

        HintText.Foreground = OverlayStyle.Brush(accent, theme.SecondaryOpacity * 0.5);
    }

    // System short-time format, so the clock matches the target wake time (12- or 24-hour per user settings).
    private void UpdateClock() =>
        ClockText.Text = _clock().ToLocalTime().ToString("t", CultureInfo.CurrentCulture);

    private static DropShadowEffect Glow(Color color, double opacity, double radius)
    {
        var effect = new DropShadowEffect
        {
            Color = color,
            Opacity = opacity,
            BlurRadius = radius * 2,
            ShadowDepth = 0,
        };
        effect.Freeze();
        return effect;
    }
}
