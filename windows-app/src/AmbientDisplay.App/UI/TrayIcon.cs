using System.ComponentModel;
using AmbientDisplay.App.Platform;
using AmbientDisplay.Core.Cloud;
using AmbientDisplay.Core.Models;
using AmbientDisplay.Core.State;
using AmbientDisplay.App.UI.Overlay;
using Microsoft.Win32;
using WinForms = System.Windows.Forms;

namespace AmbientDisplay.App.UI;

/// <summary>
/// Notification-area icon and menu, the Windows counterpart of the macOS NSStatusItem (MenuBarManager.swift).
/// The icon reflects idle / sleeping / wake-up / away; the tooltip carries the target wake time
/// (tray icons cannot show text). Double-click opens Preferences.
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly AppState _app;
    private readonly ICloudService _cloud;
    private readonly LaunchAtLoginManager _launchAtLogin;
    private readonly int _port;
    private readonly Action _openPreferences;
    private readonly Action _openLogFolder;
    private readonly Action _quit;
    private readonly WinForms.NotifyIcon _icon;
    private readonly WinForms.ContextMenuStrip _menu;
    private readonly System.Windows.Threading.Dispatcher _dispatcher = System.Windows.Threading.Dispatcher.CurrentDispatcher;
    private TrayState? _shownState;

    public TrayIcon(
        AppState app,
        ICloudService cloud,
        LaunchAtLoginManager launchAtLogin,
        int port,
        Action openPreferences,
        Action openLogFolder,
        Action quit)
    {
        _app = app;
        _cloud = cloud;
        _launchAtLogin = launchAtLogin;
        _port = port;
        _openPreferences = openPreferences;
        _openLogFolder = openLogFolder;
        _quit = quit;

        _menu = new WinForms.ContextMenuStrip();
        _menu.Opening += (_, _) => RebuildMenu();
        RebuildMenu();

        _icon = new WinForms.NotifyIcon { ContextMenuStrip = _menu, Visible = true };
        _icon.DoubleClick += (_, _) => _openPreferences();

        _app.PropertyChanged += OnAppStateChanged;
        _cloud.Changed += OnCloudChanged;
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        Refresh(force: true);
    }

    public void Dispose()
    {
        _app.PropertyChanged -= OnAppStateChanged;
        _cloud.Changed -= OnCloudChanged;
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        _icon.Visible = false;
        _icon.Icon?.Dispose();
        _icon.Dispose();
        _menu.Dispose();
    }

    private void OnAppStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppState.State) or nameof(AppState.IsAwayMode) or nameof(AppState.CurrentSession)
            or nameof(AppState.ShowCountdownInTray))
        {
            Refresh(force: false);
        }
    }

    private void OnCloudChanged(object? sender, EventArgs e) => Refresh(force: false);

    // Taskbar switched between light and dark: redraw the monochrome glyph.
    private void OnUserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.VisualStyle)
        {
            _dispatcher.BeginInvoke(() => Refresh(force: true)); // raised on a SystemEvents thread
        }
    }

    private void Refresh(bool force)
    {
        var state = _app.State switch
        {
            SessionState.WakeUpReady => TrayState.WakeUp,
            SessionState.Sleeping => TrayState.Sleeping,
            _ => _app.IsAwayMode ? TrayState.Away : TrayState.Idle,
        };

        if (force || state != _shownState)
        {
            var previous = _icon.Icon;
            _icon.Icon = TrayIconArt.Create(state);
            previous?.Dispose();
            _shownState = state;
        }

        var text = _app.State switch
        {
            SessionState.WakeUpReady => "Ambient Display — Wake Up!",
            SessionState.Sleeping when _app.ShowCountdownInTray && _app.CurrentSession is { } session =>
                $"Ambient Display — Wake at {session.FormattedTargetTime()}",
            SessionState.Sleeping => "Ambient Display — Sleeping",
            _ => _app.IsAwayMode ? "Ambient Display (Away)" : "Ambient Display",
        };

        if (_cloud.GetStatus().User is not null && _app.State == SessionState.Idle)
        {
            text += " ☁";
        }

        // NotifyIcon.Text is limited to 127 characters.
        _icon.Text = text.Length > 127 ? text[..127] : text;
    }

    private void RebuildMenu()
    {
        _menu.Items.Clear();

        // 1. Status headline
        var status = _app.State switch
        {
            SessionState.WakeUpReady => "Status: Wake Up Ready!",
            SessionState.Sleeping when _app.CurrentSession is { } session => $"Status: Sleeping (Wake: {session.FormattedTargetTime()})",
            SessionState.Sleeping => "Status: Sleeping",
            _ => _app.IsAwayMode ? "Status: Away Mode (Disabled)" : $"Status: Idle (Port {_port})",
        };
        _menu.Items.Add(new WinForms.ToolStripMenuItem(status) { Enabled = false });
        _menu.Items.Add(new WinForms.ToolStripSeparator());

        // 2. Sleep actions
        if (_app.State == SessionState.Idle)
        {
            var start = new WinForms.ToolStripMenuItem($"Start Sleep ({OverlayStyle.FormatHours(_app.DefaultSleepHours)}h Target)")
            {
                Enabled = !_app.IsAwayMode,
            };
            start.Click += (_, _) => _app.StartSleep(null, _app.DefaultSleepMinutes, "tray_manual");
            _menu.Items.Add(start);
        }
        else
        {
            _menu.Items.Add("Stop Sleep", null, (_, _) => _app.StopSleep());
        }

        // 3. Test preview
        _menu.Items.Add("Test Ambient (10s)", null, (_, _) => _app.StartTestMode(10));

        var away = new WinForms.ToolStripMenuItem("Away Mode") { Checked = _app.IsAwayMode };
        away.Click += (_, _) => _app.ToggleAwayMode();
        _menu.Items.Add(away);

        // 4. Start at login
        _menu.Items.Add(new WinForms.ToolStripSeparator());
        var login = new WinForms.ToolStripMenuItem("Start at Login") { Checked = _launchAtLogin.IsEnabled };
        login.Click += (_, _) => _launchAtLogin.SetEnabled(!_launchAtLogin.IsEnabled);
        _menu.Items.Add(login);

        // 5. Cloud & Google sign-in
        _menu.Items.Add(new WinForms.ToolStripSeparator());
        var cloud = _cloud.GetStatus();
        if (cloud.User is { } user)
        {
            _menu.Items.Add(new WinForms.ToolStripMenuItem($"☁ {user.Email ?? "Google User"}") { Enabled = false });
            var connection = cloud.IsConnected && cloud.SyncError is null ? "Online" : "Reconnecting";
            _menu.Items.Add(new WinForms.ToolStripMenuItem($"    Machine: {cloud.DeviceId} ({connection})") { Enabled = false });
            if (cloud.SyncError is { } error)
            {
                var text = error.Length > 80 ? error[..80] + "…" : error;
                _menu.Items.Add(new WinForms.ToolStripMenuItem($"    ⚠ {text}") { Enabled = false });
            }

            _menu.Items.Add("Sign Out (Google)", null, (_, _) => _cloud.SignOut());
        }
        else if (_cloud.IsSigningIn)
        {
            _menu.Items.Add(new WinForms.ToolStripMenuItem("☁ Signing in… (finish in your browser)") { Enabled = false });
        }
        else
        {
            var signIn = new WinForms.ToolStripMenuItem("☁ Sign In with Google…") { Enabled = _cloud.CanSignIn };
            signIn.Click += (_, _) => _cloud.StartGoogleOAuthFlow();
            if (!_cloud.CanSignIn)
            {
                signIn.ToolTipText = "Add Firebase settings to %APPDATA%\\AmbientDisplay\\firebase.json to enable cloud sync.";
            }

            _menu.Items.Add(signIn);
        }

        // 6. Preferences
        _menu.Items.Add(new WinForms.ToolStripSeparator());
        var preferences = new WinForms.ToolStripMenuItem("Preferences…");
        preferences.Font = new System.Drawing.Font(preferences.Font, System.Drawing.FontStyle.Bold); // default action (double-click)
        preferences.Click += (_, _) => _openPreferences();
        _menu.Items.Add(preferences);
        _menu.Items.Add("Open Log Folder", null, (_, _) => _openLogFolder());

        // 7. Quit
        _menu.Items.Add(new WinForms.ToolStripSeparator());
        _menu.Items.Add("Quit Ambient Display", null, (_, _) => _quit());
    }
}
