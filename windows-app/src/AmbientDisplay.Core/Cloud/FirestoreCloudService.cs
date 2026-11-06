using System.Globalization;
using AmbientDisplay.Core.Display;
using AmbientDisplay.Core.Server;
using AmbientDisplay.Core.Settings;
using AmbientDisplay.Core.State;
using Google.Cloud.Firestore;
using Grpc.Core;

namespace AmbientDisplay.Core.Cloud;

/// <summary>
/// Firebase cloud sync for this workstation, matching the macOS FirebaseCloudService:
/// <list type="bullet">
/// <item>Google sign-in (browser, PKCE) exchanged for a Firebase session; refresh token stored encrypted.</item>
/// <item>Presence: registers <c>users/{uid}/devices/{deviceId}</c> as a "machine" and heartbeats every 60 s.</item>
/// <item>Live Firestore listener on the fleet: shows/withdraws this PC's <c>activeCanvas</c>, clears it on local dismissal.</item>
/// <item>Two-way preference sync through <c>users/{uid}.preferences</c>.</item>
/// </list>
/// Public members are UI-thread affine; Firestore callbacks are marshalled through <see cref="IUiDispatcher"/>.
/// </summary>
public sealed class FirestoreCloudService : ICloudService, IAsyncDisposable
{
    private const string RefreshTokenSecret = "firebase-refresh-token";
    private const string UidKey = "AmbientDisplay_CloudUID";
    private const string EmailKey = "AmbientDisplay_CloudEmail";
    private const string DisplayNameKey = "AmbientDisplay_CloudDisplayName";
    private const string AppVersion = "windows-1.0.0";
    private static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan PreferencePushDelay = TimeSpan.FromSeconds(1);

    private readonly FirebaseConfig _config;
    private readonly DeviceIdentity _identity;
    private readonly AppState _app;
    private readonly DisplayCoordinator _coordinator;
    private readonly IUiDispatcher _ui;
    private readonly ISecretStore _secrets;
    private readonly ISettingsStore _settings;
    private readonly FirebaseAuthClient _auth;
    private readonly GoogleOAuth _oauth;
    private readonly Timer _heartbeat;
    private readonly Timer _preferencePush;

    private FirebaseTokenProvider? _tokens;
    private FirestoreDb? _db;
    private FirestoreChangeListener? _devicesListener;
    private FirestoreChangeListener? _userListener;
    private CancellationTokenSource? _syncCts;
    private int _listenerFailures;

    private CloudUser? _user;
    private bool _isConnected;
    private bool _isSigningIn;
    private string? _syncError;
    private DateTimeOffset? _lastSyncTime;
    private IReadOnlyList<CloudDeviceDto> _devices = [];

    private string? _cloudCanvasId;       // coordinator id of the canvas currently shown from Firestore
    private string? _lastCanvasFingerprint;

    public FirestoreCloudService(
        FirebaseConfig config,
        DeviceIdentity identity,
        AppState app,
        DisplayCoordinator coordinator,
        IUiDispatcher ui,
        ISecretStore secrets,
        ISettingsStore settings,
        HttpClient http,
        Action<Uri> openBrowser)
    {
        _config = config;
        _identity = identity;
        _app = app;
        _coordinator = coordinator;
        _ui = ui;
        _secrets = secrets;
        _settings = settings;
        _auth = new FirebaseAuthClient(config, http);
        _oauth = new GoogleOAuth(config, http, openBrowser);
        _heartbeat = new Timer(_ => _ = _ui.InvokeAsync(() => _ = SendHeartbeatAsync()), null, Timeout.Infinite, Timeout.Infinite);
        _preferencePush = new Timer(_ => _ = _ui.InvokeAsync(() => _ = PushPreferencesAsync()), null, Timeout.Infinite, Timeout.Infinite);

        _coordinator.CanvasDismissed += OnCanvasDismissed;
        _app.CloudPreferencesChanged += (_, _) =>
        {
            if (_db is not null)
            {
                _preferencePush.Change(PreferencePushDelay, Timeout.InfiniteTimeSpan);
            }
        };
    }

    public event EventHandler? Changed;

    public bool CanSignIn => _config.CanStartGoogleSignIn;

    public bool IsSigningIn => _isSigningIn;

    public IReadOnlyList<CloudDeviceDto> RegisteredDevices => _devices;

    public CloudStatus GetStatus() =>
        new(_user, _isConnected, _identity.DeviceId, _identity.DeviceName, _devices.Count, _syncError, _lastSyncTime);

    /// <summary>Resumes a saved session at startup (no browser needed).</summary>
    public Task InitializeAsync()
    {
        var refreshToken = _secrets.Read(RefreshTokenSecret);
        if (!_config.IsConfigured || string.IsNullOrEmpty(refreshToken) || !_settings.TryGet<string>(UidKey, out var uid))
        {
            return Task.CompletedTask;
        }

        _settings.TryGet<string>(EmailKey, out var email);
        _settings.TryGet<string>(DisplayNameKey, out var displayName);
        var session = new FirebaseSession(uid, email, displayName, refreshToken, string.Empty, DateTimeOffset.MinValue);
        Log.Info("Cloud", $"Resuming cloud session for {email ?? uid}.");
        return StartSyncAsync(session);
    }

    public void StartGoogleOAuthFlow()
    {
        if (_isSigningIn)
        {
            return;
        }

        if (!CanSignIn)
        {
            SetError("Cloud sync is not configured on this PC (see %APPDATA%\\AmbientDisplay\\firebase.json).");
            return;
        }

        _isSigningIn = true;
        RaiseChanged();
        _ = RunOAuthAsync();
    }

    public async Task SignInWithGoogleIdTokenAsync(string googleIdToken, CancellationToken cancellationToken)
    {
        var session = await _auth.SignInWithGoogleIdTokenAsync(googleIdToken, cancellationToken);
        await _ui.InvokeAsync(() => PersistSession(session));
        Log.Info("Cloud", $"Signed in to Firebase as {session.Email ?? session.Uid}.");
        await StartSyncAsync(session);
    }

    public void SignOut()
    {
        Log.Info("Cloud", "Signing out.");
        _ = StopSyncAsync(markOffline: true);
        _secrets.Delete(RefreshTokenSecret);
        _settings.Remove(UidKey);
        _settings.Remove(EmailKey);
        _settings.Remove(DisplayNameKey);
        _user = null;
        _devices = [];
        _syncError = null;
        _lastSyncTime = null;
        RaiseChanged();
    }

    public async ValueTask DisposeAsync()
    {
        await StopSyncAsync(markOffline: true);
        await _heartbeat.DisposeAsync();
        await _preferencePush.DisposeAsync();
    }

    // ---------------------------------------------------------------- Sign-in

    private async Task RunOAuthAsync()
    {
        try
        {
            var googleIdToken = await _oauth.SignInAsync(TimeSpan.FromMinutes(5), CancellationToken.None);
            await SignInWithGoogleIdTokenAsync(googleIdToken, CancellationToken.None);
        }
        catch (OperationCanceledException)
        {
            await _ui.InvokeAsync(() => SetError("Google sign-in timed out."));
        }
        catch (Exception ex)
        {
            Log.Info("Cloud", $"Sign-in failed: {ex.Message}");
            await _ui.InvokeAsync(() => SetError(ex.Message));
        }
        finally
        {
            await _ui.InvokeAsync(() =>
            {
                _isSigningIn = false;
                RaiseChanged();
            });
        }
    }

    private void PersistSession(FirebaseSession session)
    {
        _secrets.Write(RefreshTokenSecret, session.RefreshToken);
        _settings.Set(UidKey, session.Uid);
        _settings.Set(EmailKey, session.Email);
        _settings.Set(DisplayNameKey, session.DisplayName);
        _user = new CloudUser(session.Uid, session.Email, session.DisplayName);
        RaiseChanged();
    }

    // ---------------------------------------------------------------- Sync lifecycle

    private async Task StartSyncAsync(FirebaseSession session)
    {
        await StopSyncAsync(markOffline: false);

        var tokens = new FirebaseTokenProvider(_auth, session);
        tokens.SessionRefreshed += (_, refreshed) =>
        {
            if (refreshed.RefreshToken != session.RefreshToken)
            {
                _ = _ui.InvokeAsync(() => _secrets.Write(RefreshTokenSecret, refreshed.RefreshToken));
            }
        };

        try
        {
            await tokens.GetIdTokenAsync(CancellationToken.None, forceRefresh: string.IsNullOrEmpty(session.IdToken));
        }
        catch (SessionRevokedException ex)
        {
            await _ui.InvokeAsync(() =>
            {
                SignOut();
                SetError($"Signed out: the saved Google session is no longer valid ({ex.Message}). Please sign in again.");
            });
            return;
        }
        catch (Exception ex)
        {
            // Offline at startup: keep the session and retry on the next heartbeat.
            await _ui.InvokeAsync(() =>
            {
                _user = new CloudUser(session.Uid, session.Email, session.DisplayName);
                SetError($"Cloud unreachable: {ex.Message}");
            });
        }

        await _ui.InvokeAsync(() =>
        {
            _tokens = tokens;
            _user = new CloudUser(session.Uid, session.Email, session.DisplayName);
            _syncCts = new CancellationTokenSource();
            // Firestore accepts Firebase ID tokens as bearer tokens, so security rules see request.auth for this user.
            // The interceptor asks for a fresh token on every call; the provider refreshes it before expiry.
            var callCredentials = CallCredentials.FromInterceptor(async (context, metadata) =>
                metadata.Add("authorization", "Bearer " + await tokens.GetIdTokenAsync(context.CancellationToken)));
            _db = new FirestoreDbBuilder
            {
                ProjectId = _config.ProjectId,
                ChannelCredentials = ChannelCredentials.Create(ChannelCredentials.SecureSsl, callCredentials),
            }.Build();

            _isConnected = true;
            RaiseChanged();
            StartListeners();
            _heartbeat.Change(TimeSpan.Zero, HeartbeatInterval); // first beat registers the device
        });
    }

    private async Task StopSyncAsync(bool markOffline)
    {
        _heartbeat.Change(Timeout.Infinite, Timeout.Infinite);
        _preferencePush.Change(Timeout.Infinite, Timeout.Infinite);

        var devicesListener = _devicesListener;
        var userListener = _userListener;
        var db = _db;
        var user = _user;
        _devicesListener = null;
        _userListener = null;
        _db = null;
        _tokens = null;
        _syncCts?.Cancel();
        _syncCts = null;
        _isConnected = false;
        _cloudCanvasId = null;
        _lastCanvasFingerprint = null;

        foreach (var listener in new[] { devicesListener, userListener })
        {
            if (listener is not null)
            {
                try
                {
                    await listener.StopAsync();
                }
                catch (Exception)
                {
                    // Already faulted; nothing to stop.
                }
            }
        }

        if (markOffline && db is not null && user is not null)
        {
            try
            {
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                await DeviceDoc(db, user.Uid).SetAsync(
                    new Dictionary<string, object> { ["status"] = "offline", ["lastSeen"] = FieldValue.ServerTimestamp },
                    SetOptions.MergeAll,
                    cts.Token);
            }
            catch (Exception ex)
            {
                Log.Info("Cloud", $"Could not mark device offline: {ex.Message}");
            }
        }
    }

    private void StartListeners()
    {
        if (_db is null || _user is null)
        {
            return;
        }

        var db = _db;
        var uid = _user.Uid;

        _devicesListener = db.Collection("users").Document(uid).Collection("devices")
            .Listen(snapshot => _ = _ui.InvokeAsync(() => OnDevicesSnapshot(db, snapshot)));
        _userListener = db.Collection("users").Document(uid)
            .Listen(snapshot => _ = _ui.InvokeAsync(() => OnUserSnapshot(db, snapshot)));

        WatchListener(db, _devicesListener, "fleet");
        WatchListener(db, _userListener, "preferences");
    }

    /// <summary>Restarts the listeners with backoff if a stream fails (expired token, network loss, rules change).</summary>
    private void WatchListener(FirestoreDb db, FirestoreChangeListener listener, string name)
    {
        listener.ListenerTask.ContinueWith(task =>
        {
            if (!task.IsFaulted)
            {
                return; // stopped deliberately
            }

            var error = task.Exception?.GetBaseException();
            var auth = error is RpcException { StatusCode: StatusCode.Unauthenticated or StatusCode.PermissionDenied };
            _ = _ui.InvokeAsync(async () =>
            {
                if (!ReferenceEquals(_db, db))
                {
                    return; // signed out or restarted meanwhile
                }

                _listenerFailures++;
                var delay = TimeSpan.FromSeconds(Math.Min(300, 5 * Math.Pow(2, Math.Min(6, _listenerFailures - 1))));
                SetError($"Cloud {name} listener stopped ({error?.Message}); retrying in {delay.TotalSeconds:0}s.");

                await RestartListenersAfterAsync(db, delay, forceTokenRefresh: auth);
            });
        }, TaskScheduler.Default);
    }

    private async Task RestartListenersAfterAsync(FirestoreDb db, TimeSpan delay, bool forceTokenRefresh)
    {
        // Stop both so they restart together.
        foreach (var listener in new[] { _devicesListener, _userListener })
        {
            if (listener is not null)
            {
                try
                {
                    await listener.StopAsync();
                }
                catch (Exception)
                {
                }
            }
        }

        _devicesListener = null;
        _userListener = null;

        var token = _syncCts?.Token ?? CancellationToken.None;
        try
        {
            await Task.Delay(delay, token);
            if (forceTokenRefresh && _tokens is not null)
            {
                await _tokens.GetIdTokenAsync(token, forceRefresh: true);
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (SessionRevokedException ex)
        {
            SignOut();
            SetError($"Signed out: the saved Google session is no longer valid ({ex.Message}). Please sign in again.");
            return;
        }
        catch (Exception ex)
        {
            Log.Info("Cloud", $"Token refresh before listener restart failed: {ex.Message}");
        }

        if (ReferenceEquals(_db, db) && _devicesListener is null)
        {
            StartListeners();
        }
    }

    // ---------------------------------------------------------------- Snapshots

    private void OnDevicesSnapshot(FirestoreDb db, QuerySnapshot snapshot)
    {
        if (!ReferenceEquals(_db, db))
        {
            return;
        }

        _listenerFailures = 0;
        _syncError = null;
        _lastSyncTime = DateTimeOffset.UtcNow;

        var devices = new List<CloudDeviceDto>();
        IReadOnlyDictionary<string, object?>? myCanvas = null;
        foreach (var doc in snapshot.Documents)
        {
            var data = doc.ToDictionary();
            var deviceId = data.GetValueOrDefault("deviceId") as string ?? doc.Id;
            devices.Add(new CloudDeviceDto(
                DeviceId: deviceId,
                DeviceName: data.GetValueOrDefault("deviceName") as string ?? "Unnamed",
                DeviceType: data.GetValueOrDefault("deviceType") as string ?? "unknown",
                Status: data.GetValueOrDefault("status") as string ?? "offline",
                LastSeen: data.GetValueOrDefault("lastSeen") is Timestamp ts ? ApiJson.Iso8601(ts.ToDateTimeOffset()) : data.GetValueOrDefault("lastSeen") as string,
                ActiveCanvas: null));

            if (deviceId == _identity.DeviceId || doc.Id == _identity.DeviceId)
            {
                myCanvas = ToReadOnly(data.GetValueOrDefault("activeCanvas") as Dictionary<string, object>);
            }
        }

        _devices = devices;
        HandleActiveCanvas(CloudCanvas.Parse(myCanvas));
        RaiseChanged();
    }

    private void OnUserSnapshot(FirestoreDb db, DocumentSnapshot snapshot)
    {
        if (!ReferenceEquals(_db, db) || !snapshot.Exists)
        {
            return;
        }

        if (snapshot.TryGetValue<Dictionary<string, object>>("preferences", out var prefs) && prefs is not null)
        {
            _app.ApplyCloudPreferences(ToReadOnly(prefs)!);
        }
    }

    private void HandleActiveCanvas(CloudCanvas? canvas)
    {
        if (canvas is null)
        {
            _lastCanvasFingerprint = null;
            if (_cloudCanvasId is { } shownId)
            {
                // Withdrawn remotely (phone "Clear Screen" or another device). Forget it first so the
                // CanvasDismissed handler does not write the deletion back.
                _cloudCanvasId = null;
                Log.Info("Cloud", "Cloud canvas withdrawn; dismissing locally.");
                _coordinator.DismissCanvasById(shownId);
            }

            return;
        }

        if (canvas.Fingerprint == _lastCanvasFingerprint)
        {
            return;
        }

        _lastCanvasFingerprint = canvas.Fingerprint;
        Log.Info("Cloud", $"Cloud canvas received: [{canvas.Type}] '{canvas.Title}'.");
        var shown = _coordinator.ShowCanvas(canvas.Type, canvas.Title, canvas.Subtitle, canvas.MediaUrl, canvas.Theme,
            canvas.DismissPolicy, canvas.TargetDisplayId, canvas.DurationSeconds);
        _cloudCanvasId = shown.Id;
    }

    /// <summary>A canvas left the screen locally (ESC, click, expiry, LAN dismiss): clear it in Firestore too.</summary>
    private void OnCanvasDismissed(object? sender, string target)
    {
        if (_cloudCanvasId is null || _coordinator.IsCanvasActive(_cloudCanvasId))
        {
            return;
        }

        _cloudCanvasId = null; // keep the fingerprint so the stale snapshot does not re-show it before the delete lands
        _ = ClearActiveCanvasAsync();
    }

    // ---------------------------------------------------------------- Writes

    private async Task SendHeartbeatAsync()
    {
        if (_db is not { } db || _user is not { } user)
        {
            return;
        }

        try
        {
            await DeviceDoc(db, user.Uid).SetAsync(new Dictionary<string, object>
            {
                ["deviceId"] = _identity.DeviceId,
                ["deviceName"] = _identity.DeviceName,
                ["deviceType"] = "machine", // what the Android fleet picker targets (same as macOS)
                ["status"] = "online",
                ["lastSeen"] = FieldValue.ServerTimestamp,
                ["appVersion"] = AppVersion,
            }, SetOptions.MergeAll);
            _lastSyncTime = DateTimeOffset.UtcNow;
            if (_syncError is not null && _devicesListener is not null)
            {
                _syncError = null;
                RaiseChanged();
            }
        }
        catch (Exception ex)
        {
            SetError($"Heartbeat failed: {ex.Message}");
        }
    }

    private async Task ClearActiveCanvasAsync()
    {
        if (_db is not { } db || _user is not { } user)
        {
            return;
        }

        try
        {
            await DeviceDoc(db, user.Uid).UpdateAsync("activeCanvas", FieldValue.Delete);
            Log.Info("Cloud", "Cleared activeCanvas in Firestore.");
        }
        catch (Exception ex)
        {
            Log.Info("Cloud", $"Could not clear activeCanvas: {ex.Message}");
        }
    }

    private async Task PushPreferencesAsync()
    {
        if (_db is not { } db || _user is not { } user)
        {
            return;
        }

        var data = new Dictionary<string, object>
        {
            ["userId"] = user.Uid,
            ["preferences"] = _app.GetCloudPreferences(),
            ["updatedAt"] = FieldValue.ServerTimestamp,
        };
        if (!string.IsNullOrEmpty(user.Email))
        {
            data["email"] = user.Email;
        }

        if (!string.IsNullOrEmpty(user.DisplayName))
        {
            data["displayName"] = user.DisplayName;
        }

        try
        {
            await db.Collection("users").Document(user.Uid).SetAsync(data, SetOptions.MergeAll);
            Log.Info("Cloud", "Pushed preferences to Firestore.");
        }
        catch (Exception ex)
        {
            SetError($"Preference sync failed: {ex.Message}");
        }
    }

    // ---------------------------------------------------------------- Helpers

    private DocumentReference DeviceDoc(FirestoreDb db, string uid) =>
        db.Collection("users").Document(uid).Collection("devices").Document(_identity.DeviceId);

    private void SetError(string message)
    {
        _syncError = message;
        Log.Info("Cloud", message);
        RaiseChanged();
    }

    private void RaiseChanged() => Changed?.Invoke(this, EventArgs.Empty);

    private static IReadOnlyDictionary<string, object?>? ToReadOnly(Dictionary<string, object>? map) =>
        map?.ToDictionary(kv => kv.Key, kv => (object?)kv.Value, StringComparer.Ordinal);

    internal static string Describe(object? value) => Convert.ToString(value, CultureInfo.InvariantCulture) ?? "null";
}
