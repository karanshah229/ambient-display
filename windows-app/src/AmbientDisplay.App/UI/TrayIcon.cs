using System.ComponentModel;
using System.Globalization;
using AmbientDisplay.Core.Models;
using AmbientDisplay.Core.State;
using WinForms = System.Windows.Forms;

namespace AmbientDisplay.App.UI;

/// <summary>
/// Notification-area icon and menu (the Windows counterpart of the macOS NSStatusItem).
/// Minimal for M1; the full menu (cloud, launch at login, preferences) arrives in M3.
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly AppState _app;
    private readonly int _port;
    private readonly Action _openLogFolder;
    private readonly Action _quit;
    private readonly WinForms.NotifyIcon _icon;
    private readonly WinForms.ContextMenuStrip _menu;

    public TrayIcon(AppState app, int port, Action openLogFolder, Action quit)
    {
        _app = app;
        _port = port;
        _openLogFolder = openLogFolder;
        _quit = quit;

        _menu = new WinForms.ContextMenuStrip();
        _menu.Opening += (_, _) => RebuildMenu();
        RebuildMenu();

        _icon = new WinForms.NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Application,
            ContextMenuStrip = _menu,
            Visible = true,
        };

        _app.PropertyChanged += OnAppStateChanged;
        RefreshTooltip();
    }

    public void Dispose()
    {
        _app.PropertyChanged -= OnAppStateChanged;
        _icon.Visible = false;
        _icon.Dispose();
        _menu.Dispose();
    }

    private void OnAppStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppState.State) or nameof(AppState.IsAwayMode) or nameof(AppState.CurrentSession)
            or nameof(AppState.ShowCountdownInTray))
        {
            RefreshTooltip();
        }
    }

    private void RefreshTooltip()
    {
        var text = _app.State switch
        {
            SessionState.WakeUpReady => "Ambient Display — Wake Up!",
            SessionState.Sleeping when _app.ShowCountdownInTray && _app.CurrentSession is { } session =>
                $"Ambient Display — Wake at {session.FormattedTargetTime()}",
            SessionState.Sleeping => "Ambient Display — Sleeping",
            _ => _app.IsAwayMode ? "Ambient Display (Away)" : "Ambient Display",
        };

        // NotifyIcon.Text is limited to 127 characters.
        _icon.Text = text.Length > 127 ? text[..127] : text;
    }

    private void RebuildMenu()
    {
        _menu.Items.Clear();

        var status = _app.State switch
        {
            SessionState.WakeUpReady => "Status: Wake Up Ready!",
            SessionState.Sleeping when _app.CurrentSession is { } session => $"Status: Sleeping (Wake: {session.FormattedTargetTime()})",
            SessionState.Sleeping => "Status: Sleeping",
            _ => _app.IsAwayMode ? "Status: Away Mode (Disabled)" : $"Status: Idle (Port {_port})",
        };
        _menu.Items.Add(new WinForms.ToolStripMenuItem(status) { Enabled = false });
        _menu.Items.Add(new WinForms.ToolStripSeparator());

        if (_app.State == SessionState.Idle)
        {
            var hours = _app.DefaultSleepHours;
            var hoursText = hours % 1 == 0 ? hours.ToString("0", CultureInfo.CurrentCulture) : hours.ToString("0.0", CultureInfo.CurrentCulture);
            _menu.Items.Add($"Start Sleep ({hoursText}h Target)", null, (_, _) =>
                _app.StartSleep(null, _app.DefaultSleepMinutes, "tray_manual"));
        }
        else
        {
            _menu.Items.Add("Stop Sleep", null, (_, _) => _app.StopSleep());
        }

        _menu.Items.Add("Test Ambient (10s)", null, (_, _) => _app.StartTestMode(10));

        var away = new WinForms.ToolStripMenuItem("Away Mode") { Checked = _app.IsAwayMode };
        away.Click += (_, _) => _app.ToggleAwayMode();
        _menu.Items.Add(away);

        _menu.Items.Add(new WinForms.ToolStripSeparator());
        _menu.Items.Add("Open Log Folder", null, (_, _) => _openLogFolder());
        _menu.Items.Add(new WinForms.ToolStripSeparator());
        _menu.Items.Add("Quit Ambient Display", null, (_, _) => _quit());
    }
}
