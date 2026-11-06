using System.Net;
using System.Security.Cryptography;
using System.Text;
using AmbientDisplay.Core.Cloud;
using AmbientDisplay.Core.Display;

namespace AmbientDisplay.Tests;

public class CloudCanvasTests
{
    [Fact]
    public void ParsesAndroidSnakeCasePayload()
    {
        var canvas = CloudCanvas.Parse(new Dictionary<string, object?>
        {
            ["type"] = "image",
            ["title"] = "Nature",
            ["subtitle"] = "  Yosemite ",
            ["media_url"] = "https://example.com/a.jpg",
            ["dismiss_policy"] = "phone_only",
            ["target_display_id"] = "aaaa0001",
            ["created_at"] = "2026-11-06T17:00:00Z",
        });

        Assert.NotNull(canvas);
        Assert.Equal(CanvasPayloadType.Image, canvas.Type);
        Assert.Equal("Yosemite", canvas.Subtitle);
        Assert.Equal("https://example.com/a.jpg", canvas.MediaUrl);
        Assert.Equal(DismissPolicy.PhoneOnly, canvas.DismissPolicy);
        Assert.Equal("aaaa0001", canvas.TargetDisplayId);
        Assert.Null(canvas.DurationSeconds);
    }

    [Fact]
    public void ParsesCamelCaseAndFirestoreLongDuration()
    {
        var canvas = CloudCanvas.Parse(new Dictionary<string, object?>
        {
            ["title"] = "Hi",
            ["mediaUrl"] = "",
            ["dismissPolicy"] = "phoneOnly",
            ["durationSeconds"] = 30L,
        });

        Assert.NotNull(canvas);
        Assert.Equal(CanvasPayloadType.Billboard, canvas.Type);
        Assert.Null(canvas.MediaUrl);
        Assert.Equal(DismissPolicy.PhoneOnly, canvas.DismissPolicy);
        Assert.Equal("all", canvas.TargetDisplayId);
        Assert.Equal(30, canvas.DurationSeconds);
    }

    [Fact]
    public void EmptyOrContentlessMapMeansNothingShowing()
    {
        Assert.Null(CloudCanvas.Parse(null));
        Assert.Null(CloudCanvas.Parse(new Dictionary<string, object?>()));
        Assert.Null(CloudCanvas.Parse(new Dictionary<string, object?> { ["subtitle"] = "x", ["dismiss_policy"] = "esc_any" }));
    }

    [Fact]
    public void MediaOnlyCanvasGetsDefaultTitle()
    {
        var canvas = CloudCanvas.Parse(new Dictionary<string, object?> { ["media_url"] = "https://example.com/v.mp4", ["type"] = "video" });

        Assert.NotNull(canvas);
        Assert.Equal("Ambient Display", canvas.Title);
        Assert.Equal(CanvasPayloadType.Video, canvas.Type);
    }

    [Fact]
    public void FingerprintChangesWhenResentAndIsStableOtherwise()
    {
        Dictionary<string, object?> Payload(string created) => new() { ["title"] = "BRB", ["created_at"] = created };

        var first = CloudCanvas.Parse(Payload("t1"))!;
        var same = CloudCanvas.Parse(Payload("t1"))!;
        var resent = CloudCanvas.Parse(Payload("t2"))!;

        Assert.Equal(first.Fingerprint, same.Fingerprint);
        Assert.NotEqual(first.Fingerprint, resent.Fingerprint);
    }
}

public class GoogleOAuthTests
{
    [Fact]
    public void PkceChallengeIsS256OfVerifier()
    {
        var verifier = GoogleOAuth.CreateCodeVerifier();
        var expected = Convert.ToBase64String(SHA256.HashData(Encoding.ASCII.GetBytes(verifier))).TrimEnd('=').Replace('+', '-').Replace('/', '_');

        Assert.InRange(verifier.Length, 43, 128);
        Assert.DoesNotContain('=', verifier);
        Assert.Equal(expected, GoogleOAuth.CodeChallenge(verifier));
    }

    [Fact]
    public void AuthorizeUriCarriesPkceStateAndLoopbackRedirect()
    {
        var uri = GoogleOAuth.BuildAuthorizeUri("client.apps.googleusercontent.com", "http://127.0.0.1:5555/", "st@te", "chal");
        var query = uri.Query;

        Assert.StartsWith("https://accounts.google.com/o/oauth2/v2/auth?", uri.AbsoluteUri);
        Assert.Contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A5555%2F", query);
        Assert.Contains("code_challenge_method=S256", query);
        Assert.Contains("state=st%40te", query);
        Assert.Contains("scope=openid%20email%20profile", query);
    }

    [Fact]
    public void RedirectWithMatchingStateYieldsCode()
    {
        var result = GoogleOAuth.ParseRedirect("GET /?state=abc&code=4%2F0Ab_x&scope=email HTTP/1.1", "abc");

        Assert.Equal(GoogleOAuth.RedirectKind.Code, result.Kind);
        Assert.Equal("4/0Ab_x", result.Code);
    }

    [Fact]
    public void RedirectWithWrongStateIsRejected()
    {
        var result = GoogleOAuth.ParseRedirect("GET /?state=evil&code=123 HTTP/1.1", "abc");

        Assert.Equal(GoogleOAuth.RedirectKind.Error, result.Kind);
        Assert.Null(result.Code);
    }

    [Fact]
    public void UserCancellationIsReportedAndFaviconIgnored()
    {
        Assert.Equal("access_denied", GoogleOAuth.ParseRedirect("GET /?state=abc&error=access_denied HTTP/1.1", "abc").Error);
        Assert.Equal(GoogleOAuth.RedirectKind.Ignore, GoogleOAuth.ParseRedirect("GET /favicon.ico HTTP/1.1", "abc").Kind);
        Assert.Equal(GoogleOAuth.RedirectKind.Ignore, GoogleOAuth.ParseRedirect("POST /?state=abc&code=1 HTTP/1.1", "abc").Kind);
    }
}

public sealed class FirebaseConfigTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), $"firebase-{Guid.NewGuid():N}.json");

    public void Dispose()
    {
        if (File.Exists(_path))
        {
            File.Delete(_path);
        }
    }

    [Fact]
    public void LoadsFileAndEnvironmentOverrides()
    {
        File.WriteAllText(_path, """{ "projectId": "p-file", "apiKey": "k-file", "oauthClientId": "c-file", "oauthClientSecret": "s-file" }""");
        var env = new Dictionary<string, string> { ["FIREBASE_API_KEY"] = "k-env" };

        var config = FirebaseConfig.Load(_path, name => env.GetValueOrDefault(name));

        Assert.Equal("p-file", config.ProjectId);
        Assert.Equal("k-env", config.ApiKey);
        Assert.Equal("c-file", config.OAuthClientId);
        Assert.Equal("s-file", config.OAuthClientSecret);
        Assert.True(config.CanStartGoogleSignIn);
    }

    [Fact]
    public void MissingFileMeansNotConfigured()
    {
        var config = FirebaseConfig.Load(_path, _ => null);

        Assert.False(config.IsConfigured);
        Assert.False(config.CanStartGoogleSignIn);
    }
}

public class FirebaseTokenProviderTests
{
    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public int Calls { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            return Task.FromResult(respond(request));
        }
    }

    private static readonly FirebaseConfig Config = new("proj", "key", "client", "secret");

    [Fact]
    public async Task ReusesValidTokenAndRefreshesNearExpiry()
    {
        var time = new ManualTimeProvider(DateTimeOffset.UnixEpoch.AddYears(56));
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("""{ "id_token": "fresh", "refresh_token": "r2", "expires_in": "3600" }"""),
        });
        var auth = new FirebaseAuthClient(Config, new HttpClient(handler), time);
        var provider = new FirebaseTokenProvider(auth, new FirebaseSession("uid", null, null, "r1", "old", time.GetUtcNow().AddMinutes(30)), time);
        FirebaseSession? persisted = null;
        provider.SessionRefreshed += (_, s) => persisted = s;

        Assert.Equal("old", await provider.GetIdTokenAsync(CancellationToken.None));
        Assert.Equal(0, handler.Calls);

        time.Advance(TimeSpan.FromMinutes(26)); // 4 minutes left: inside the refresh margin
        Assert.Equal("fresh", await provider.GetIdTokenAsync(CancellationToken.None));
        Assert.Equal(1, handler.Calls);
        Assert.Equal("r2", persisted?.RefreshToken);
    }

    [Fact]
    public async Task RevokedRefreshTokenRaisesSessionRevoked()
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.BadRequest)
        {
            Content = new StringContent("""{ "error": { "message": "TOKEN_EXPIRED" } }"""),
        });
        var auth = new FirebaseAuthClient(Config, new HttpClient(handler));
        var provider = new FirebaseTokenProvider(auth, new FirebaseSession("uid", null, null, "r1", string.Empty, DateTimeOffset.MinValue));

        await Assert.ThrowsAsync<SessionRevokedException>(() => provider.GetIdTokenAsync(CancellationToken.None));
    }

    [Fact]
    public async Task SignInWithIdpMapsFirebaseResponse()
    {
        string? requestedUrl = null;
        var handler = new StubHandler(request =>
        {
            requestedUrl = request.RequestUri!.AbsoluteUri;
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("""{ "localId": "u1", "email": "a@b.com", "displayName": "A", "idToken": "id", "refreshToken": "rt", "expiresIn": "3600" }"""),
            };
        });
        var auth = new FirebaseAuthClient(Config, new HttpClient(handler));

        var session = await auth.SignInWithGoogleIdTokenAsync("google-jwt", CancellationToken.None);

        Assert.Equal("https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=key", requestedUrl);
        Assert.Equal("u1", session.Uid);
        Assert.Equal("a@b.com", session.Email);
        Assert.Equal("rt", session.RefreshToken);
    }
}
