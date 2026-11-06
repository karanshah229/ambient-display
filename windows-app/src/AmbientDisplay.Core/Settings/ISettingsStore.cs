using System.Text.Json;

namespace AmbientDisplay.Core.Settings;

/// <summary>Key/value preference storage (the Windows stand-in for macOS UserDefaults).</summary>
public interface ISettingsStore
{
    bool TryGet<T>(string key, out T value);

    void Set<T>(string key, T value);

    void Remove(string key);
}

/// <summary>
/// JSON-file backed settings store. Writes are atomic (temp file + replace).
/// Pass a null path for an in-memory store (used by tests).
/// </summary>
public sealed class JsonSettingsStore : ISettingsStore
{
    private static readonly JsonSerializerOptions FileOptions = new() { WriteIndented = true };

    private readonly string? _filePath;
    private readonly Dictionary<string, JsonElement> _values;
    private readonly Lock _lock = new();

    public JsonSettingsStore(string? filePath)
    {
        _filePath = filePath;
        _values = Load(filePath);
    }

    public static JsonSettingsStore InMemory() => new(null);

    public string? FilePath => _filePath;

    public bool TryGet<T>(string key, out T value)
    {
        lock (_lock)
        {
            if (_values.TryGetValue(key, out var element))
            {
                try
                {
                    var parsed = element.Deserialize<T>();
                    if (parsed is not null)
                    {
                        value = parsed;
                        return true;
                    }
                }
                catch (JsonException)
                {
                    // Wrong type stored under this key; treat as missing.
                }
            }
        }

        value = default!;
        return false;
    }

    public void Set<T>(string key, T value)
    {
        lock (_lock)
        {
            if (value is null)
            {
                _values.Remove(key);
            }
            else
            {
                _values[key] = JsonSerializer.SerializeToElement(value);
            }

            Persist();
        }
    }

    public void Remove(string key)
    {
        lock (_lock)
        {
            if (_values.Remove(key))
            {
                Persist();
            }
        }
    }

    private static Dictionary<string, JsonElement> Load(string? filePath)
    {
        if (filePath is null || !File.Exists(filePath))
        {
            return new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        }

        try
        {
            using var stream = File.OpenRead(filePath);
            var loaded = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(stream);
            return loaded is null
                ? new Dictionary<string, JsonElement>(StringComparer.Ordinal)
                : new Dictionary<string, JsonElement>(loaded, StringComparer.Ordinal);
        }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
        {
            Log.Info("Settings", $"Could not read {filePath}; starting with defaults. ({ex.Message})");
            return new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        }
    }

    private void Persist()
    {
        if (_filePath is null)
        {
            return;
        }

        try
        {
            var directory = Path.GetDirectoryName(_filePath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var tempPath = _filePath + ".tmp";
            File.WriteAllText(tempPath, JsonSerializer.Serialize(_values, FileOptions));
            File.Move(tempPath, _filePath, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Info("Settings", $"Failed to save settings: {ex.Message}");
        }
    }
}
