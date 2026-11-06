using AmbientDisplay.Core;
using AmbientDisplay.Core.Settings;
using AmbientDisplay.Core.State;
using Microsoft.Win32;

namespace AmbientDisplay.App.Platform;

/// <summary>
/// "Start at login" via the per-user Run key (<c>HKCU\Software\Microsoft\Windows\CurrentVersion\Run</c>), the
/// unpackaged-app equivalent of macOS SMAppService. No admin rights needed. The registry is the source of truth;
/// the preference is kept so a moved or rebuilt exe re-registers itself on the next launch.
/// </summary>
internal sealed class LaunchAtLoginManager
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "AmbientDisplay";

    private readonly ISettingsStore _settings;
    private readonly string _command;

    public LaunchAtLoginManager(ISettingsStore settings, string? executablePath = null)
    {
        _settings = settings;
        var exe = executablePath ?? Environment.ProcessPath ?? throw new InvalidOperationException("Unknown executable path.");
        _command = $"\"{exe}\"";
    }

    public bool IsEnabled => string.Equals(ReadRegistered(), _command, StringComparison.OrdinalIgnoreCase);

    /// <summary>Re-registers if the user asked for it but the entry is missing or points at an old location.</summary>
    public void Refresh()
    {
        var requested = _settings.TryGet<bool>(PreferenceKeys.LaunchAtLogin, out var value) && value;
        if (requested && !IsEnabled)
        {
            Log.Info("LaunchAtLogin", "Restoring the Run entry (missing or pointing at an old path).");
            Write(true);
        }
    }

    public void SetEnabled(bool enabled)
    {
        _settings.Set(PreferenceKeys.LaunchAtLogin, enabled);
        Write(enabled);
    }

    private void Write(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
            if (enabled)
            {
                key.SetValue(ValueName, _command, RegistryValueKind.String);
            }
            else if (key.GetValue(ValueName) is not null)
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }

            Log.Info("LaunchAtLogin", enabled ? $"Registered: {_command}" : "Unregistered.");
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            Log.Info("LaunchAtLogin", $"Could not update the Run key: {ex.Message}");
        }
    }

    private static string? ReadRegistered()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
        return key?.GetValue(ValueName) as string;
    }
}
