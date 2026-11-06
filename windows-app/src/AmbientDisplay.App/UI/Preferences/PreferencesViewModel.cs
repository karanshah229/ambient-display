using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows.Input;
using System.Windows.Media;
using AmbientDisplay.App.Platform;
using AmbientDisplay.Core.Cloud;
using AmbientDisplay.Core.Display;
using AmbientDisplay.Core.State;

namespace AmbientDisplay.App.UI.Preferences;

/// <summary>Backs the Preferences window (port of macOS PreferencesView.swift). Preferences bind straight to AppState.</summary>
internal sealed class PreferencesViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly LaunchAtLoginManager _launchAtLogin;
    private readonly IDisplayProvider _displays;
    private readonly ICloudService _cloud;
    private readonly int _port;
    private readonly Func<string?> _advertisedServiceName;

    public PreferencesViewModel(
        AppState app,
        LaunchAtLoginManager launchAtLogin,
        IDisplayProvider displays,
        ICloudService cloud,
        int port,
        Func<string?> advertisedServiceName)
    {
        App = app;
        _launchAtLogin = launchAtLogin;
        _displays = displays;
        _cloud = cloud;
        _port = port;
        _advertisedServiceName = advertisedServiceName;

        Hours = Enumerable.Range(0, 24)
            .Select(h => new HourOption(h, DateTime.Today.AddHours(h).ToString("t", CultureInfo.CurrentCulture)))
            .ToList();

        ResetColorsCommand = new RelayCommand(App.ResetAmbientDefaults);
        TestAmbientCommand = new RelayCommand(() => App.StartTestMode(10));
        OpenStatusPageCommand = new RelayCommand(() => Process.Start(new ProcessStartInfo($"http://127.0.0.1:{_port}/") { UseShellExecute = true }));
        SignInCommand = new RelayCommand(_cloud.StartGoogleOAuthFlow);
        SignOutCommand = new RelayCommand(_cloud.SignOut);

        App.PropertyChanged += OnAppChanged;
        _displays.DisplaysChanged += OnDisplaysChanged;
        _cloud.Changed += OnCloudChanged;
        RefreshDisplays();
        RefreshCloud();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public AppState App { get; }

    public IReadOnlyList<HourOption> Hours { get; }

    public ICommand ResetColorsCommand { get; }

    public ICommand TestAmbientCommand { get; }

    public ICommand OpenStatusPageCommand { get; }

    public ICommand SignInCommand { get; }

    public ICommand SignOutCommand { get; }

    // ---------------------------------------------------------------- General

    public bool LaunchAtLogin
    {
        get => _launchAtLogin.IsEnabled;
        set
        {
            _launchAtLogin.SetEnabled(value);
            OnPropertyChanged();
        }
    }

    // ---------------------------------------------------------------- Sleep

    public string SleepHoursLabel => $"{App.DefaultSleepHours.ToString("0.#", CultureInfo.CurrentCulture)} hours";

    public string OffsetLabel => $"{App.InactivityOffsetMinutes:0} minutes";

    public bool IsCustomOffset => !App.AutoDetectInactivityOffset;

    // ---------------------------------------------------------------- Displays

    public ObservableCollection<DisplayRow> Displays { get; } = [];

    public string DisplaysHeader => $"Detected displays ({Displays.Count})";

    // ---------------------------------------------------------------- Ambient colours

    public string NightHex
    {
        get => App.AmbientNightColorHex;
        set => SetHex(value, h => App.AmbientNightColorHex = h);
    }

    public string DawnHex
    {
        get => App.AmbientDawnColorHex;
        set => SetHex(value, h => App.AmbientDawnColorHex = h);
    }

    public string WakeHex
    {
        get => App.AmbientWakeColorHex;
        set => SetHex(value, h => App.AmbientWakeColorHex = h);
    }

    public Brush NightBrush => BrushFor(App.AmbientNightColorHex);

    public Brush DawnBrush => BrushFor(App.AmbientDawnColorHex);

    public Brush WakeBrush => BrushFor(App.AmbientWakeColorHex);

    // ---------------------------------------------------------------- Network

    public string LanAddress => MdnsAdvertiser.FindLanAddress() is { } lan ? $"{lan.Address}:{_port}" : $"No network ({_port})";

    public string DiscoveryStatus => _advertisedServiceName() is { } name
        ? $"Advertised as {name}"
        : "Not advertised (the phone can still find this PC by scanning the network)";

    public string StatusPageUrl => $"http://127.0.0.1:{_port}/";

    // ---------------------------------------------------------------- Cloud

    public bool IsSignedIn => _cloud.GetStatus().User is not null;

    public bool IsSignedOut => !IsSignedIn;

    public bool CanSignIn => _cloud.CanSignIn && !_cloud.IsSigningIn;

    public string CloudHeadline
    {
        get
        {
            var status = _cloud.GetStatus();
            if (status.User is { } user)
            {
                return $"Signed in as {user.Email ?? user.DisplayName ?? user.Uid}";
            }

            if (_cloud.IsSigningIn)
            {
                return "Signing in… finish in your browser.";
            }

            return _cloud.CanSignIn
                ? "Sign in with Google to receive canvases from anywhere and appear in your phone's fleet."
                : "Cloud sync is off. Add Firebase settings to %APPDATA%\\AmbientDisplay\\firebase.json to enable it.";
        }
    }

    public string DeviceIdentity
    {
        get
        {
            var status = _cloud.GetStatus();
            return $"{status.DeviceName}  •  {status.DeviceId}";
        }
    }

    public string SyncState
    {
        get
        {
            var status = _cloud.GetStatus();
            if (status.User is null)
            {
                return string.Empty;
            }

            if (status.SyncError is { } error)
            {
                return $"⚠ {error}";
            }

            return status.LastSyncTime is { } last
                ? $"Connected. Last sync {last.ToLocalTime():t}."
                : status.IsConnected ? "Connecting…" : "Offline";
        }
    }

    public ObservableCollection<FleetRow> Fleet { get; } = [];

    public string FleetHeader => $"Devices in your account ({Fleet.Count})";

    public void Dispose()
    {
        App.PropertyChanged -= OnAppChanged;
        _displays.DisplaysChanged -= OnDisplaysChanged;
        _cloud.Changed -= OnCloudChanged;
    }

    private void OnAppChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppState.DefaultSleepHours):
                OnPropertyChanged(nameof(SleepHoursLabel));
                break;
            case nameof(AppState.InactivityOffsetMinutes):
                OnPropertyChanged(nameof(OffsetLabel));
                break;
            case nameof(AppState.AutoDetectInactivityOffset):
                OnPropertyChanged(nameof(IsCustomOffset));
                break;
            case nameof(AppState.AmbientNightColorHex):
                OnPropertyChanged(nameof(NightHex));
                OnPropertyChanged(nameof(NightBrush));
                break;
            case nameof(AppState.AmbientDawnColorHex):
                OnPropertyChanged(nameof(DawnHex));
                OnPropertyChanged(nameof(DawnBrush));
                break;
            case nameof(AppState.AmbientWakeColorHex):
                OnPropertyChanged(nameof(WakeHex));
                OnPropertyChanged(nameof(WakeBrush));
                break;
            case nameof(AppState.IgnoredDisplayIds):
                RefreshDisplays();
                break;
        }
    }

    private void OnDisplaysChanged(object? sender, EventArgs e)
    {
        RefreshDisplays();
        OnPropertyChanged(nameof(LanAddress));
    }

    private void OnCloudChanged(object? sender, EventArgs e) => RefreshCloud();

    private void RefreshDisplays()
    {
        Displays.Clear();
        foreach (var display in _displays.GetDisplays())
        {
            Displays.Add(new DisplayRow(display, !App.IsDisplayIgnored(display.Id), enabled => App.SetDisplayIgnored(display.Id, !enabled)));
        }

        OnPropertyChanged(nameof(DisplaysHeader));
    }

    private void RefreshCloud()
    {
        Fleet.Clear();
        foreach (var device in _cloud.RegisteredDevices)
        {
            Fleet.Add(FleetRow.From(device, _cloud.GetStatus().DeviceId));
        }

        foreach (var name in new[] { nameof(IsSignedIn), nameof(IsSignedOut), nameof(CanSignIn), nameof(CloudHeadline), nameof(DeviceIdentity), nameof(SyncState), nameof(FleetHeader) })
        {
            OnPropertyChanged(name);
        }
    }

    private void SetHex(string value, Action<string> apply, [CallerMemberName] string? property = null)
    {
        var normalized = SolarCalculator.NormalizeHex(value, fallback: string.Empty);
        if (normalized.Length > 0)
        {
            apply(normalized);
        }

        OnPropertyChanged(property); // reverts the text box when the input was invalid
    }

    private static Brush BrushFor(string hex)
    {
        var color = OverlayColor(hex);
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private static Color OverlayColor(string hex) =>
        Overlay.OverlayStyle.FromHex(hex, Colors.Gray);

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

internal sealed record HourOption(int Value, string Label);

internal sealed class DisplayRow : INotifyPropertyChanged
{
    private readonly Action<bool> _setEnabled;
    private bool _isEnabled;

    public DisplayRow(DisplayInfo display, bool isEnabled, Action<bool> setEnabled)
    {
        Display = display;
        _isEnabled = isEnabled;
        _setEnabled = setEnabled;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public DisplayInfo Display { get; }

    public string Title => Display.IsPrimary ? $"{Display.Name}  (primary)" : Display.Name;

    public string Details => $"{Display.Width} × {Display.Height} px  •  ID {Display.Id}";

    /// <summary>Checked = ambient and canvas surfaces may use this monitor (the inverse of "ignored").</summary>
    public bool IsEnabled
    {
        get => _isEnabled;
        set
        {
            if (_isEnabled == value)
            {
                return;
            }

            _isEnabled = value;
            _setEnabled(value);
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsEnabled)));
        }
    }
}

internal sealed record FleetRow(string Name, string Details, string Presence, bool IsOnline)
{
    public static FleetRow From(Core.Server.CloudDeviceDto device, string thisDeviceId)
    {
        // Same rule as the Android app: online when the last heartbeat is under 90 seconds old.
        var online = DateTimeOffset.TryParse(device.LastSeen, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var seen)
            && DateTimeOffset.UtcNow - seen < TimeSpan.FromSeconds(90);
        var name = device.DeviceId == thisDeviceId ? $"{device.DeviceName} (this PC)" : device.DeviceName;
        return new FleetRow(name, $"{device.DeviceId}  •  {device.DeviceType.ToUpperInvariant()}", online ? "ONLINE" : "OFFLINE", online);
    }
}

internal sealed class RelayCommand(Action execute) : ICommand
{
    public event EventHandler? CanExecuteChanged
    {
        add { }
        remove { }
    }

    public bool CanExecute(object? parameter) => true;

    public void Execute(object? parameter) => execute();
}
