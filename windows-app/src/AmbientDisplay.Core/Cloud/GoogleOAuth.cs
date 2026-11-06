using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AmbientDisplay.Core.Cloud;

/// <summary>
/// Google sign-in for installed apps: authorization-code flow with PKCE (S256) and a <c>state</c> check,
/// redirected to a one-shot loopback listener on 127.0.0.1 with a random port (RFC 8252).
/// Replaces the macOS flow, which used a fixed port and no PKCE.
/// </summary>
public sealed class GoogleOAuth
{
    private const string AuthorizeEndpoint = "https://accounts.google.com/o/oauth2/v2/auth";
    private const string TokenEndpoint = "https://oauth2.googleapis.com/token";

    private readonly FirebaseConfig _config;
    private readonly HttpClient _http;
    private readonly Action<Uri> _openBrowser;

    public GoogleOAuth(FirebaseConfig config, HttpClient http, Action<Uri> openBrowser)
    {
        _config = config;
        _http = http;
        _openBrowser = openBrowser;
    }

    /// <summary>Opens the browser, waits for the redirect, and returns Google's OpenID Connect ID token.</summary>
    public async Task<string> SignInAsync(TimeSpan timeout, CancellationToken cancellationToken)
    {
        if (!_config.CanStartGoogleSignIn)
        {
            throw new InvalidOperationException("Google sign-in is not configured (missing OAuth client ID).");
        }

        var verifier = CreateCodeVerifier();
        var state = Base64Url(RandomNumberGenerator.GetBytes(16));

        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var redirectUri = $"http://127.0.0.1:{port}/";

        _openBrowser(BuildAuthorizeUri(_config.OAuthClientId, redirectUri, state, CodeChallenge(verifier)));
        Log.Info("OAuth", $"Waiting for Google sign-in on {redirectUri}");

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(timeout);

        string code;
        while (true)
        {
            using var client = await listener.AcceptTcpClientAsync(timeoutCts.Token).ConfigureAwait(false);
            var stream = client.GetStream();
            var requestLine = await ReadRequestLineAsync(stream, timeoutCts.Token).ConfigureAwait(false);
            var result = ParseRedirect(requestLine, state);

            if (result.Kind == RedirectKind.Ignore)
            {
                // e.g. a favicon request; answer and keep waiting for the real redirect.
                await WriteResponseAsync(stream, 404, "Not found", timeoutCts.Token).ConfigureAwait(false);
                continue;
            }

            var page = result.Kind == RedirectKind.Code
                ? "<h1 style=\"color:#30D158\">&#10003; Signed in</h1><p>Ambient Display on this PC is now connected to your Google account. You can close this tab.</p>"
                : $"<h1 style=\"color:#FF453A\">Sign-in failed</h1><p>{WebUtility.HtmlEncode(result.Error)}</p>";
            await WriteResponseAsync(stream, result.Kind == RedirectKind.Code ? 200 : 400, Html(page), timeoutCts.Token).ConfigureAwait(false);

            if (result.Kind != RedirectKind.Code)
            {
                throw new InvalidOperationException($"Google sign-in failed: {result.Error}");
            }

            code = result.Code!;
            break;
        }

        return await ExchangeCodeAsync(code, verifier, redirectUri, cancellationToken).ConfigureAwait(false);
    }

    internal static Uri BuildAuthorizeUri(string clientId, string redirectUri, string state, string codeChallenge)
    {
        var query = string.Join('&', new Dictionary<string, string>
        {
            ["client_id"] = clientId,
            ["redirect_uri"] = redirectUri,
            ["response_type"] = "code",
            ["scope"] = "openid email profile",
            ["state"] = state,
            ["code_challenge"] = codeChallenge,
            ["code_challenge_method"] = "S256",
            ["prompt"] = "select_account",
        }.Select(kv => $"{kv.Key}={Uri.EscapeDataString(kv.Value)}"));
        return new Uri($"{AuthorizeEndpoint}?{query}");
    }

    internal static string CreateCodeVerifier() => Base64Url(RandomNumberGenerator.GetBytes(32)); // 43 chars

    internal static string CodeChallenge(string verifier) => Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));

    internal enum RedirectKind
    {
        Code,
        Error,
        Ignore,
    }

    internal readonly record struct RedirectResult(RedirectKind Kind, string? Code, string? Error);

    /// <summary>Parses "GET /?state=..&amp;code=.. HTTP/1.1". Rejects a mismatched state (CSRF protection).</summary>
    internal static RedirectResult ParseRedirect(string? requestLine, string expectedState)
    {
        var parts = (requestLine ?? string.Empty).Split(' ');
        if (parts.Length < 2 || parts[0] != "GET")
        {
            return new(RedirectKind.Ignore, null, null);
        }

        var target = parts[1];
        var queryIndex = target.IndexOf('?');
        var path = queryIndex >= 0 ? target[..queryIndex] : target;
        if (path != "/" || queryIndex < 0)
        {
            return new(RedirectKind.Ignore, null, null);
        }

        var query = target[(queryIndex + 1)..]
            .Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(pair => pair.Split('=', 2))
            .ToDictionary(p => Uri.UnescapeDataString(p[0]), p => p.Length > 1 ? Uri.UnescapeDataString(p[1].Replace('+', ' ')) : string.Empty);

        if (!query.TryGetValue("state", out var state) || !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(state), Encoding.UTF8.GetBytes(expectedState)))
        {
            return new(RedirectKind.Error, null, "The sign-in response did not match this request. Please try again.");
        }

        if (query.TryGetValue("error", out var error))
        {
            return new(RedirectKind.Error, null, error);
        }

        return query.TryGetValue("code", out var code) && code.Length > 0
            ? new(RedirectKind.Code, code, null)
            : new(RedirectKind.Error, null, "No authorization code was returned.");
    }

    private async Task<string> ExchangeCodeAsync(string code, string verifier, string redirectUri, CancellationToken cancellationToken)
    {
        var form = new Dictionary<string, string>
        {
            ["code"] = code,
            ["client_id"] = _config.OAuthClientId,
            ["redirect_uri"] = redirectUri,
            ["grant_type"] = "authorization_code",
            ["code_verifier"] = verifier,
        };

        // Google issues a (non-confidential) secret for Desktop clients and expects it on the exchange.
        if (_config.OAuthClientSecret.Length > 0)
        {
            form["client_secret"] = _config.OAuthClientSecret;
        }

        using var response = await _http.PostAsync(TokenEndpoint, new FormUrlEncodedContent(form), cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"Google token exchange failed ({(int)response.StatusCode}): {ExtractError(body)}");
        }

        using var json = JsonDocument.Parse(body);
        return json.RootElement.TryGetProperty("id_token", out var idToken) && idToken.GetString() is { Length: > 0 } token
            ? token
            : throw new InvalidOperationException("Google did not return an ID token.");
    }

    private static async Task<string?> ReadRequestLineAsync(NetworkStream stream, CancellationToken cancellationToken)
    {
        var buffer = new byte[8192];
        var read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
        var text = Encoding.ASCII.GetString(buffer, 0, read);
        var end = text.IndexOf("\r\n", StringComparison.Ordinal);
        return end >= 0 ? text[..end] : text;
    }

    private static async Task WriteResponseAsync(NetworkStream stream, int status, string html, CancellationToken cancellationToken)
    {
        var body = Encoding.UTF8.GetBytes(html);
        var reason = status switch { 200 => "OK", 404 => "Not Found", _ => "Bad Request" };
        var header = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {reason}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(body, cancellationToken).ConfigureAwait(false);
    }

    private static string Html(string inner) =>
        $"<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Ambient Display</title></head>" +
        $"<body style=\"font-family:'Segoe UI',system-ui,sans-serif;background:#121212;color:#fff;text-align:center;padding-top:80px\">{inner}</body></html>";

    internal static string ExtractError(string body)
    {
        try
        {
            using var json = JsonDocument.Parse(body);
            var root = json.RootElement;
            if (root.TryGetProperty("error_description", out var description))
            {
                return description.GetString() ?? body;
            }

            if (root.TryGetProperty("error", out var error))
            {
                return error.ValueKind == JsonValueKind.Object && error.TryGetProperty("message", out var message)
                    ? message.GetString() ?? body
                    : error.ToString();
            }
        }
        catch (JsonException)
        {
        }

        return body.Length > 300 ? body[..300] : body;
    }

    private static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
