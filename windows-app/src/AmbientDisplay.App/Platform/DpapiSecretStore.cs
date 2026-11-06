using System.Security.Cryptography;
using System.Text;
using AmbientDisplay.Core;
using AmbientDisplay.Core.Cloud;

namespace AmbientDisplay.App.Platform;

/// <summary>
/// Stores secrets (the Firebase refresh token) encrypted with DPAPI for the current Windows user, under
/// <c>%APPDATA%\AmbientDisplay\secrets</c>. Other users and other machines cannot decrypt them.
/// (macOS kept the token in plain UserDefaults.)
/// </summary>
internal sealed class DpapiSecretStore : ISecretStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("AmbientDisplay.Windows.v1");
    private readonly string _directory;

    public DpapiSecretStore(string directory)
    {
        _directory = directory;
    }

    public string? Read(string name)
    {
        var path = PathFor(name);
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            var plain = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }
        catch (Exception ex) when (ex is CryptographicException or IOException or UnauthorizedAccessException)
        {
            Log.Info("Secrets", $"Could not read secret '{name}': {ex.Message}");
            return null;
        }
    }

    public void Write(string name, string value)
    {
        Directory.CreateDirectory(_directory);
        var cipher = ProtectedData.Protect(Encoding.UTF8.GetBytes(value), Entropy, DataProtectionScope.CurrentUser);
        var path = PathFor(name);
        File.WriteAllBytes(path + ".tmp", cipher);
        File.Move(path + ".tmp", path, overwrite: true);
    }

    public void Delete(string name)
    {
        var path = PathFor(name);
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }

    private string PathFor(string name)
    {
        var safe = string.Concat(name.Select(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' ? c : '_'));
        return Path.Combine(_directory, safe + ".bin");
    }
}
