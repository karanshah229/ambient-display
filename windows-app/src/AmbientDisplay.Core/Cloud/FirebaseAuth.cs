using System.Net.Http.Json;
using System.Text.Json;

namespace AmbientDisplay.Core.Cloud;

/// <summary>Signed-in Firebase user. The refresh token is the long-lived secret; ID tokens last an hour.</summary>
public sealed record FirebaseSession(
    string Uid,
    string? Email,
    string? DisplayName,
    string RefreshToken,
    string IdToken,
    DateTimeOffset IdTokenExpiresAt);

/// <summary>Persists the refresh token encrypted for the current Windows user (DPAPI in the WPF host).</summary>
public interface ISecretStore
{
    string? Read(string name);

    void Write(string name, string value);

    void Delete(string name);
}

/// <summary>Firebase Auth REST client: Google ID token -> Firebase session, and ID-token refresh.</summary>
public sealed class FirebaseAuthClient
{
    private readonly FirebaseConfig _config;
    private readonly HttpClient _http;
    private readonly TimeProvider _time;

    public FirebaseAuthClient(FirebaseConfig config, HttpClient http, TimeProvider? time = null)
    {
        _config = config;
        _http = http;
        _time = time ?? TimeProvider.System;
    }

    /// <summary>accounts:signInWithIdp with a Google OpenID Connect token (same call as the macOS app).</summary>
    public async Task<FirebaseSession> SignInWithGoogleIdTokenAsync(string googleIdToken, CancellationToken cancellationToken)
    {
        var url = $"https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key={Uri.EscapeDataString(_config.ApiKey)}";
        var payload = new
        {
            postBody = $"id_token={Uri.EscapeDataString(googleIdToken)}&providerId=google.com",
            requestUri = "http://localhost",
            returnIdpCredential = true,
            returnSecureToken = true,
        };

        using var response = await _http.PostAsJsonAsync(url, payload, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"Firebase sign-in failed ({(int)response.StatusCode}): {GoogleOAuth.ExtractError(body)}");
        }

        using var json = JsonDocument.Parse(body);
        var root = json.RootElement;
        return new FirebaseSession(
            Uid: root.GetProperty("localId").GetString()!,
            Email: OptionalString(root, "email"),
            DisplayName: OptionalString(root, "displayName"),
            RefreshToken: root.GetProperty("refreshToken").GetString()!,
            IdToken: root.GetProperty("idToken").GetString()!,
            IdTokenExpiresAt: ExpiresAt(root, "expiresIn"));
    }

    /// <summary>securetoken grant_type=refresh_token. Throws <see cref="SessionRevokedException"/> when the refresh token is dead.</summary>
    public async Task<FirebaseSession> RefreshAsync(FirebaseSession session, CancellationToken cancellationToken)
    {
        var url = $"https://securetoken.googleapis.com/v1/token?key={Uri.EscapeDataString(_config.ApiKey)}";
        var form = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["grant_type"] = "refresh_token",
            ["refresh_token"] = session.RefreshToken,
        });

        using var response = await _http.PostAsync(url, form, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            var error = GoogleOAuth.ExtractError(body);
            if ((int)response.StatusCode is 400 or 401 or 403 && error.Contains("TOKEN", StringComparison.OrdinalIgnoreCase)
                || error.Contains("USER_DISABLED", StringComparison.Ordinal) || error.Contains("USER_NOT_FOUND", StringComparison.Ordinal))
            {
                throw new SessionRevokedException(error);
            }

            throw new HttpRequestException($"Token refresh failed ({(int)response.StatusCode}): {error}");
        }

        using var json = JsonDocument.Parse(body);
        var root = json.RootElement;
        return session with
        {
            RefreshToken = OptionalString(root, "refresh_token") ?? session.RefreshToken,
            IdToken = root.GetProperty("id_token").GetString()!,
            IdTokenExpiresAt = ExpiresAt(root, "expires_in"),
        };
    }

    private DateTimeOffset ExpiresAt(JsonElement root, string property)
    {
        var seconds = root.TryGetProperty(property, out var value) && int.TryParse(value.GetString(), out var parsed) ? parsed : 3600;
        return _time.GetUtcNow().AddSeconds(seconds);
    }

    private static string? OptionalString(JsonElement root, string property) =>
        root.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}

/// <summary>The stored session can no longer be refreshed (revoked, user deleted); the user must sign in again.</summary>
public sealed class SessionRevokedException(string message) : Exception(message);

/// <summary>
/// Hands out a valid Firebase ID token, refreshing it five minutes before expiry. Thread-safe; used by the
/// Firestore gRPC interceptor on every call.
/// </summary>
public sealed class FirebaseTokenProvider
{
    private static readonly TimeSpan RefreshMargin = TimeSpan.FromMinutes(5);

    private readonly FirebaseAuthClient _auth;
    private readonly TimeProvider _time;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private FirebaseSession _session;

    public FirebaseTokenProvider(FirebaseAuthClient auth, FirebaseSession session, TimeProvider? time = null)
    {
        _auth = auth;
        _session = session;
        _time = time ?? TimeProvider.System;
    }

    /// <summary>Raised (on a background thread) after a refresh, so the new refresh token can be persisted.</summary>
    public event EventHandler<FirebaseSession>? SessionRefreshed;

    public FirebaseSession Session => _session;

    public async Task<string> GetIdTokenAsync(CancellationToken cancellationToken, bool forceRefresh = false)
    {
        var current = _session;
        if (!forceRefresh && current.IdTokenExpiresAt - _time.GetUtcNow() > RefreshMargin)
        {
            return current.IdToken;
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!forceRefresh && _session.IdTokenExpiresAt - _time.GetUtcNow() > RefreshMargin)
            {
                return _session.IdToken;
            }

            _session = await _auth.RefreshAsync(_session, cancellationToken).ConfigureAwait(false);
            SessionRefreshed?.Invoke(this, _session);
            return _session.IdToken;
        }
        finally
        {
            _gate.Release();
        }
    }
}
