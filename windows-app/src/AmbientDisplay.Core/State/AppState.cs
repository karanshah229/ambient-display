using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using AmbientDisplay.Core.Models;
using AmbientDisplay.Core.Settings;

namespace AmbientDisplay.Core.State;

/// <summary>Persisted preference keys. Names match the macOS UserDefaults keys.</summary>
public static class PreferenceKeys
{
    public const string IsAwayMode = "AmbientDisplay_isAwayMode";
    public const string DefaultSleepHours = "AmbientDisplay_defaultSleepHours";
    public const string LegacyDefaultSleepMinutes = "AmbientDisplay_defaultSleepMinutes";
    public const string InactivityOffsetMinutes = "AmbientDisplay_inactivityOffsetMinutes";
    public const string AutoDetectInactivityOffset = "AmbientDisplay_autoDetectInactivityOffset";
    public const string SleepWindowStartHour = "AmbientDisplay_sleepWindowStartHour";
    public const string SleepWindowEndHour = "AmbientDisplay_sleepWindowEndHour";
    public const string AutoPushWindowStartHour = "AmbientDisplay_autoPushWindowStartHour";
    public const string AutoPushWindowEndHour = "AmbientDisplay_autoPushWindowEndHour";
    public const string IgnoredDisplayIds = "AmbientDisplay_ignoredDisplayIDs";
    public const string AmbientNightColorHex = "AmbientDisplay_ambientNightColorHex";
    public const string AmbientDawnColorHex = "AmbientDisplay_ambientDawnColorHex";
    public const string AmbientWakeColorHex = "AmbientDisplay_ambientWakeColorHex";
    public const string ShowCountdownInTray = "AmbientDisplay_showCountdownInMenuBar";
    public const string LaunchAtLogin = "AmbientDisplay_launchAtLogin";
    public const string CloudDeviceId = "AmbientDisplay_CloudDeviceId";
}

/// <summary>
/// Sleep-session state machine plus user preferences. UI-thread affine (like the macOS @MainActor class):
/// every member must be called on the dispatcher thread. Port of macOS <c>AppState.swift</c>.
/// </summary>
public sealed class AppState : INotifyPropertyChanged
{
    public const string DefaultNightColorHex = "#D95926"; // Deep Night Ember
    public const string DefaultDawnColorHex = "#FA7268";  // Sunrise Coral
    public const string DefaultWakeColorHex = "#FFD000";  // Radiant Solar Gold

    private readonly ISettingsStore? _store;
    private readonly TimeProvider _time;
    private readonly HashSet<string> _ignoredDisplayIds;
    private bool _isApplyingCloudPreferences;

    private SessionState _state = SessionState.Idle;
    private SleepSession? _currentSession;
    private bool _isTestMode;
    private DateTimeOffset _lastUpdated;

    private bool _isAwayMode;
    private double _defaultSleepHours;
    private double _inactivityOffsetMinutes;
    private bool _autoDetectInactivityOffset;
    private int _sleepWindowStartHour;
    private int _sleepWindowEndHour;
    private int _autoPushWindowStartHour;
    private int _autoPushWindowEndHour;
    private string _ambientNightColorHex;
    private string _ambientDawnColorHex;
    private string _ambientWakeColorHex;
    private bool _showCountdownInTray;

    public AppState(ISettingsStore? store, TimeProvider? timeProvider = null)
    {
        _store = store;
        _time = timeProvider ?? TimeProvider.System;
        _lastUpdated = _time.GetUtcNow();

        _isAwayMode = Get(PreferenceKeys.IsAwayMode, false);

        var savedHours = Get(PreferenceKeys.DefaultSleepHours, 0.0);
        if (savedHours > 0)
        {
            _defaultSleepHours = savedHours;
        }
        else
        {
            var legacyMinutes = Get(PreferenceKeys.LegacyDefaultSleepMinutes, 0.0);
            _defaultSleepHours = legacyMinutes > 0 ? legacyMinutes / 60.0 : 7.5;
        }

        var savedOffset = Get(PreferenceKeys.InactivityOffsetMinutes, 0.0);
        _inactivityOffsetMinutes = savedOffset > 0 ? savedOffset : 30.0;
        _autoDetectInactivityOffset = Get(PreferenceKeys.AutoDetectInactivityOffset, true);

        _sleepWindowStartHour = Get(PreferenceKeys.SleepWindowStartHour, 21);
        _sleepWindowEndHour = Get(PreferenceKeys.SleepWindowEndHour, 6);
        _autoPushWindowStartHour = Get(PreferenceKeys.AutoPushWindowStartHour, 21);
        _autoPushWindowEndHour = Get(PreferenceKeys.AutoPushWindowEndHour, 23);

        _ignoredDisplayIds = new HashSet<string>(
            Get(PreferenceKeys.IgnoredDisplayIds, Array.Empty<string>()),
            StringComparer.OrdinalIgnoreCase);

        _ambientNightColorHex = Get(PreferenceKeys.AmbientNightColorHex, DefaultNightColorHex);

        // Upgrade legacy amber palettes to the natural sunrise defaults (same rules as macOS).
        var savedDawn = Get<string?>(PreferenceKeys.AmbientDawnColorHex, null);
        _ambientDawnColorHex = savedDawn is null || savedDawn == "#FFBF66" ? DefaultDawnColorHex : savedDawn;
        var savedWake = Get<string?>(PreferenceKeys.AmbientWakeColorHex, null);
        _ambientWakeColorHex = savedWake is null || savedWake is "#40E68C" or "#FFB800" ? DefaultWakeColorHex : savedWake;

        _showCountdownInTray = Get(PreferenceKeys.ShowCountdownInTray, true);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Raised on every state assignment (even if unchanged), mirroring the @Published publisher.</summary>
    public event EventHandler<SessionState>? StateChanged;

    /// <summary>Raised when a cloud-synced preference changes locally (not while applying cloud values).</summary>
    public event EventHandler? CloudPreferencesChanged;

    public DateTimeOffset Now => _time.GetUtcNow();

    // ---------------------------------------------------------------- Session state

    public SessionState State => _state;

    public SleepSession? CurrentSession => _currentSession;

    public bool IsTestMode => _isTestMode;

    public DateTimeOffset LastUpdated => _lastUpdated;

    // ---------------------------------------------------------------- Preferences

    public bool IsAwayMode
    {
        get => _isAwayMode;
        set
        {
            if (SetPreference(ref _isAwayMode, value, PreferenceKeys.IsAwayMode, cloudSynced: true))
            {
                HandleAwayModeChanged();
            }
        }
    }

    public double DefaultSleepHours
    {
        get => _defaultSleepHours;
        set
        {
            if (SetPreference(ref _defaultSleepHours, value, PreferenceKeys.DefaultSleepHours, cloudSynced: true))
            {
                OnPropertyChanged(nameof(DefaultSleepMinutes));
            }
        }
    }

    public double DefaultSleepMinutes => _defaultSleepHours * 60.0;

    public double InactivityOffsetMinutes
    {
        get => _inactivityOffsetMinutes;
        set => SetPreference(ref _inactivityOffsetMinutes, value, PreferenceKeys.InactivityOffsetMinutes, cloudSynced: true);
    }

    public bool AutoDetectInactivityOffset
    {
        get => _autoDetectInactivityOffset;
        set => SetPreference(ref _autoDetectInactivityOffset, value, PreferenceKeys.AutoDetectInactivityOffset, cloudSynced: true);
    }

    public int SleepWindowStartHour
    {
        get => _sleepWindowStartHour;
        set => SetPreference(ref _sleepWindowStartHour, value, PreferenceKeys.SleepWindowStartHour, cloudSynced: true);
    }

    public int SleepWindowEndHour
    {
        get => _sleepWindowEndHour;
        set => SetPreference(ref _sleepWindowEndHour, value, PreferenceKeys.SleepWindowEndHour, cloudSynced: true);
    }

    public int AutoPushWindowStartHour
    {
        get => _autoPushWindowStartHour;
        set => SetPreference(ref _autoPushWindowStartHour, value, PreferenceKeys.AutoPushWindowStartHour, cloudSynced: true);
    }

    public int AutoPushWindowEndHour
    {
        get => _autoPushWindowEndHour;
        set => SetPreference(ref _autoPushWindowEndHour, value, PreferenceKeys.AutoPushWindowEndHour, cloudSynced: true);
    }

    public string AmbientNightColorHex
    {
        get => _ambientNightColorHex;
        set => SetPreference(ref _ambientNightColorHex, value, PreferenceKeys.AmbientNightColorHex, cloudSynced: true);
    }

    public string AmbientDawnColorHex
    {
        get => _ambientDawnColorHex;
        set => SetPreference(ref _ambientDawnColorHex, value, PreferenceKeys.AmbientDawnColorHex, cloudSynced: true);
    }

    public string AmbientWakeColorHex
    {
        get => _ambientWakeColorHex;
        set => SetPreference(ref _ambientWakeColorHex, value, PreferenceKeys.AmbientWakeColorHex, cloudSynced: true);
    }

    public bool ShowCountdownInTray
    {
        get => _showCountdownInTray;
        set => SetPreference(ref _showCountdownInTray, value, PreferenceKeys.ShowCountdownInTray, cloudSynced: false);
    }

    // ---------------------------------------------------------------- Ignored displays

    /// <summary>
    /// Stable display IDs (derived from the monitor device path) excluded from ambient/canvas surfaces.
    /// macOS also matched by monitor name; Windows IDs are already stable, and matching by name would
    /// wrongly ignore every identical monitor model.
    /// </summary>
    public IReadOnlySet<string> IgnoredDisplayIds => _ignoredDisplayIds;

    public bool IsDisplayIgnored(string displayId) => _ignoredDisplayIds.Contains(displayId);

    public void SetDisplayIgnored(string displayId, bool ignored)
    {
        var changed = ignored ? _ignoredDisplayIds.Add(displayId) : _ignoredDisplayIds.Remove(displayId);
        if (!changed)
        {
            return;
        }

        _store?.Set(PreferenceKeys.IgnoredDisplayIds, _ignoredDisplayIds.Order(StringComparer.OrdinalIgnoreCase).ToArray());
        OnPropertyChanged(nameof(IgnoredDisplayIds));
    }

    public void ToggleDisplayIgnored(string displayId) => SetDisplayIgnored(displayId, !IsDisplayIgnored(displayId));

    public void ResetAmbientDefaults()
    {
        AmbientNightColorHex = DefaultNightColorHex;
        AmbientDawnColorHex = DefaultDawnColorHex;
        AmbientWakeColorHex = DefaultWakeColorHex;
    }

    // ---------------------------------------------------------------- Cloud preference sync

    /// <summary>Applies preferences received from Firestore without echoing them back to the cloud.</summary>
    public void ApplyCloudPreferences(IReadOnlyDictionary<string, object?> prefs)
    {
        _isApplyingCloudPreferences = true;
        try
        {
            if (prefs.TryGetValue("isAwayMode", out var away) && away is bool awayValue)
            {
                IsAwayMode = awayValue;
            }

            if (TryGetDouble(prefs, "defaultSleepHours", out var hours) && hours > 0)
            {
                DefaultSleepHours = hours;
            }

            if (TryGetInt(prefs, "sleepWindowStartHour", out var sleepStart))
            {
                SleepWindowStartHour = sleepStart;
            }

            if (TryGetInt(prefs, "sleepWindowEndHour", out var sleepEnd))
            {
                SleepWindowEndHour = sleepEnd;
            }

            if (TryGetInt(prefs, "autoPushWindowStartHour", out var pushStart))
            {
                AutoPushWindowStartHour = pushStart;
            }

            if (TryGetInt(prefs, "autoPushWindowEndHour", out var pushEnd))
            {
                AutoPushWindowEndHour = pushEnd;
            }

            if (TryGetDouble(prefs, "inactivityOffsetMinutes", out var offset) && offset > 0)
            {
                InactivityOffsetMinutes = offset;
            }

            if (prefs.TryGetValue("autoDetectInactivity", out var autoDetect) && autoDetect is bool autoDetectValue)
            {
                AutoDetectInactivityOffset = autoDetectValue;
            }

            if (prefs.TryGetValue("ambientNightColorHex", out var night) && night is string nightValue)
            {
                AmbientNightColorHex = nightValue;
            }

            if (prefs.TryGetValue("ambientDawnColorHex", out var dawn) && dawn is string dawnValue)
            {
                AmbientDawnColorHex = dawnValue;
            }

            if (prefs.TryGetValue("ambientWakeColorHex", out var wake) && wake is string wakeValue)
            {
                AmbientWakeColorHex = wakeValue;
            }
        }
        finally
        {
            _isApplyingCloudPreferences = false;
        }
    }

    /// <summary>The preference map pushed to <c>users/{uid}.preferences</c> (same keys as macOS/Android).</summary>
    public Dictionary<string, object> GetCloudPreferences() => new()
    {
        ["isAwayMode"] = IsAwayMode,
        ["defaultSleepHours"] = DefaultSleepHours,
        ["sleepWindowStartHour"] = SleepWindowStartHour,
        ["sleepWindowEndHour"] = SleepWindowEndHour,
        ["autoPushWindowStartHour"] = AutoPushWindowStartHour,
        ["autoPushWindowEndHour"] = AutoPushWindowEndHour,
        ["inactivityOffsetMinutes"] = InactivityOffsetMinutes,
        ["autoDetectInactivity"] = AutoDetectInactivityOffset,
        ["ambientNightColorHex"] = AmbientNightColorHex,
        ["ambientDawnColorHex"] = AmbientDawnColorHex,
        ["ambientWakeColorHex"] = AmbientWakeColorHex,
    };

    // ---------------------------------------------------------------- Session transitions

    public void StartSleep(DateTimeOffset? bedtime = null, double durationMinutes = SleepSession.DefaultDurationMinutes, string reason = "auto")
    {
        if (_isAwayMode)
        {
            Log.Info("AppState", "Sleep event ignored because Away Mode is active.");
            return;
        }

        var now = Now;
        var session = SleepSession.FromDuration(bedtime ?? now, durationMinutes, reason, createdAt: now);
        _currentSession = session;
        _isTestMode = false;
        SetState(session.IsExpired(now) ? SessionState.WakeUpReady : SessionState.Sleeping);
        SetLastUpdated(now);
        OnPropertyChanged(nameof(CurrentSession));
        OnPropertyChanged(nameof(IsTestMode));

        Log.Info("AppState", $"Started sleep session: Bedtime = {session.FormattedBedtime()}, Target = {session.FormattedTargetTime()} ({durationMinutes.ToString(CultureInfo.InvariantCulture)} mins, reason: {reason})");
    }

    public void StartTestMode(int durationSeconds = 10)
    {
        var now = Now;
        var session = SleepSession.FromTarget(
            bedtime: now - TimeSpan.FromMinutes(SleepSession.DefaultDurationMinutes), // pretend fell asleep 7.5h ago
            targetWakeTime: now + TimeSpan.FromSeconds(durationSeconds),
            reason: "test",
            createdAt: now);
        _currentSession = session;
        _isTestMode = true;
        SetState(SessionState.Sleeping);
        SetLastUpdated(now);
        OnPropertyChanged(nameof(CurrentSession));
        OnPropertyChanged(nameof(IsTestMode));

        Log.Info("AppState", $"Started Test Mode with {durationSeconds}s duration.");
    }

    public void TriggerWakeUpReady()
    {
        SetState(SessionState.WakeUpReady);
        SetLastUpdated(Now);
        Log.Info("AppState", "Target time reached -> State is now wakeUpReady!");
    }

    public void DismissWakeUp() => StopSleep();

    public void StopSleep()
    {
        _currentSession = null;
        _isTestMode = false;
        SetState(SessionState.Idle);
        SetLastUpdated(Now);
        OnPropertyChanged(nameof(CurrentSession));
        OnPropertyChanged(nameof(IsTestMode));
        Log.Info("AppState", "Sleep session stopped/idle.");
    }

    public void ToggleAwayMode() => IsAwayMode = !IsAwayMode;

    /// <summary>Called once per second by the host. Advances the countdown and fires wake-up.</summary>
    public void Tick()
    {
        if (_currentSession is null || _state != SessionState.Sleeping)
        {
            return;
        }

        var now = Now;
        SetLastUpdated(now);
        if (_currentSession.IsExpired(now))
        {
            TriggerWakeUpReady();
        }
    }

    // ---------------------------------------------------------------- Helpers

    private void HandleAwayModeChanged()
    {
        if (_isAwayMode && _state != SessionState.Idle)
        {
            StopSleep();
        }

        Log.Info("AppState", $"Away Mode is now: {_isAwayMode}");
    }

    private void SetState(SessionState state)
    {
        _state = state;
        OnPropertyChanged(nameof(State));
        StateChanged?.Invoke(this, state);
    }

    private void SetLastUpdated(DateTimeOffset value)
    {
        _lastUpdated = value;
        OnPropertyChanged(nameof(LastUpdated));
    }

    private bool SetPreference<T>(ref T field, T value, string key, bool cloudSynced, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        _store?.Set(key, value);
        OnPropertyChanged(propertyName);

        if (cloudSynced && !_isApplyingCloudPreferences)
        {
            CloudPreferencesChanged?.Invoke(this, EventArgs.Empty);
        }

        return true;
    }

    private T Get<T>(string key, T fallback) =>
        _store is not null && _store.TryGet<T>(key, out var value) ? value : fallback;

    private void OnPropertyChanged(string? propertyName) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));

    private static bool TryGetDouble(IReadOnlyDictionary<string, object?> prefs, string key, out double value)
    {
        value = 0;
        if (!prefs.TryGetValue(key, out var raw) || raw is null || raw is bool or string)
        {
            return false;
        }

        try
        {
            value = Convert.ToDouble(raw, CultureInfo.InvariantCulture);
            return true;
        }
        catch (Exception ex) when (ex is InvalidCastException or FormatException or OverflowException)
        {
            return false;
        }
    }

    private static bool TryGetInt(IReadOnlyDictionary<string, object?> prefs, string key, out int value)
    {
        value = 0;
        if (!TryGetDouble(prefs, key, out var number))
        {
            return false;
        }

        value = (int)number;
        return true;
    }
}
