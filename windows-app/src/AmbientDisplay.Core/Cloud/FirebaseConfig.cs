using System.Text.Json;

namespace AmbientDisplay.Core.Cloud;

/// <summary>
/// Firebase project + Google OAuth "Desktop app" client settings. Never committed: loaded from
/// <c>%APPDATA%\AmbientDisplay\firebase.json</c>, with environment variables taking precedence
/// (<c>FIREBASE_PROJECT_ID</c>, <c>FIREBASE_API_KEY</c>, <c>FIREBASE_CLIENT_ID</c>, <c>FIREBASE_CLIENT_SECRET</c>,
/// the same names the macOS app reads).
/// </summary>
public sealed record FirebaseConfig(string ProjectId, string ApiKey, string OAuthClientId, string OAuthClientSecret)
{
    public static readonly FirebaseConfig Empty = new(string.Empty, string.Empty, string.Empty, string.Empty);

    /// <summary>Enough to call Firestore and Firebase Auth (Google sign-in additionally needs the OAuth client).</summary>
    public bool IsConfigured => ProjectId.Length > 0 && ApiKey.Length > 0;

    public bool CanStartGoogleSignIn => IsConfigured && OAuthClientId.Length > 0;

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AmbientDisplay", "firebase.json");

    public static FirebaseConfig Load(string? path = null, Func<string, string?>? environment = null)
    {
        environment ??= Environment.GetEnvironmentVariable;
        var file = ReadFile(path ?? DefaultPath);

        string Pick(string envName, string? fileValue) =>
            (environment(envName) is { Length: > 0 } fromEnv ? fromEnv : fileValue ?? string.Empty).Trim();

        return new FirebaseConfig(
            ProjectId: Pick("FIREBASE_PROJECT_ID", file?.ProjectId),
            ApiKey: Pick("FIREBASE_API_KEY", file?.ApiKey),
            OAuthClientId: Pick("FIREBASE_CLIENT_ID", file?.OAuthClientId),
            OAuthClientSecret: Pick("FIREBASE_CLIENT_SECRET", file?.OAuthClientSecret));
    }

    private static FileModel? ReadFile(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            return JsonSerializer.Deserialize<FileModel>(File.ReadAllText(path), new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
        {
            Log.Info("Cloud", $"Could not read {path}: {ex.Message}");
            return null;
        }
    }

    private sealed class FileModel
    {
        public string? ProjectId { get; init; }
        public string? ApiKey { get; init; }
        public string? OAuthClientId { get; init; }
        public string? OAuthClientSecret { get; init; }
    }
}
