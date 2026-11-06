using System.Net;
using System.Text;
using AmbientDisplay.Core.Server;
using AmbientDisplay.Core.Settings;
using AmbientDisplay.Core.State;

namespace AmbientDisplay.Core.Cloud;

public sealed record CloudUser(string Uid, string? Email, string? DisplayName);

public sealed record CloudStatus(
    CloudUser? User,
    bool IsConnected,
    string DeviceId,
    string DeviceName,
    int RegisteredDevicesCount,
    string? SyncError,
    DateTimeOffset? LastSyncTime);

/// <summary>Firebase cloud sync (Google sign-in, fleet presence, remote canvases). UI-thread affine.</summary>
public interface ICloudService
{
    /// <summary>Raised on the UI thread whenever sign-in state, connection or the fleet list changes.</summary>
    event EventHandler? Changed;

    /// <summary>Firebase and the Google OAuth client are configured, so "Sign in with Google" can work.</summary>
    bool CanSignIn { get; }

    bool IsSigningIn { get; }

    CloudStatus GetStatus();

    IReadOnlyList<CloudDeviceDto> RegisteredDevices { get; }

    Task SignInWithGoogleIdTokenAsync(string googleIdToken, CancellationToken cancellationToken);

    void StartGoogleOAuthFlow();

    void SignOut();
}

/// <summary>Used when Firebase is not configured on this PC. Reports a signed-out device.</summary>
public sealed class DisabledCloudService : ICloudService
{
    private readonly DeviceIdentity _identity;
    private string? _syncError;

    public DisabledCloudService(DeviceIdentity identity)
    {
        _identity = identity;
    }

    public event EventHandler? Changed
    {
        add { }
        remove { }
    }

    public bool CanSignIn => false;

    public bool IsSigningIn => false;

    public IReadOnlyList<CloudDeviceDto> RegisteredDevices => [];

    public CloudStatus GetStatus() =>
        new(null, false, _identity.DeviceId, _identity.DeviceName, 0, _syncError, null);

    public Task SignInWithGoogleIdTokenAsync(string googleIdToken, CancellationToken cancellationToken) =>
        throw new InvalidOperationException("Cloud sync is not configured on this PC (see %APPDATA%\\AmbientDisplay\\firebase.json).");

    public void StartGoogleOAuthFlow()
    {
        _syncError = "Cloud sync is not configured on this PC (see %APPDATA%\\AmbientDisplay\\firebase.json).";
        Log.Info("Cloud", _syncError);
    }

    public void SignOut()
    {
    }
}

/// <summary>This workstation's identity in the Firestore fleet (<c>users/{uid}/devices/{deviceId}</c>).</summary>
public sealed class DeviceIdentity
{
    private readonly ISettingsStore _store;
    private readonly string _hostName;

    public DeviceIdentity(ISettingsStore store, string? hostName = null)
    {
        _store = store;
        _hostName = string.IsNullOrWhiteSpace(hostName) ? SafeHostName() : hostName;
    }

    public string DeviceName => _hostName;

    /// <summary>Persisted "machine_&lt;host&gt;" ID, generated the same way as on macOS.</summary>
    public string DeviceId
    {
        get
        {
            if (_store.TryGet<string>(PreferenceKeys.CloudDeviceId, out var stored) && !string.IsNullOrEmpty(stored))
            {
                return stored;
            }

            var generated = GenerateDeviceId(_hostName);
            _store.Set(PreferenceKeys.CloudDeviceId, generated);
            return generated;
        }
    }

    public static string GenerateDeviceId(string hostName)
    {
        var tokens = new List<string>();
        var current = new StringBuilder();
        foreach (var ch in hostName.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(ch))
            {
                current.Append(ch);
            }
            else if (current.Length > 0)
            {
                tokens.Add(current.ToString());
                current.Clear();
            }
        }

        if (current.Length > 0)
        {
            tokens.Add(current.ToString());
        }

        var clean = string.Join('_', tokens);
        return "machine_" + (clean.Length > 20 ? clean[..20] : clean);
    }

    private static string SafeHostName()
    {
        try
        {
            var name = Dns.GetHostName();
            return string.IsNullOrWhiteSpace(name) ? Environment.MachineName : name;
        }
        catch (Exception)
        {
            return string.IsNullOrWhiteSpace(Environment.MachineName) ? "Windows Workstation" : Environment.MachineName;
        }
    }
}
