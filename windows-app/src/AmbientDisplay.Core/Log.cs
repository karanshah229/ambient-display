namespace AmbientDisplay.Core;

/// <summary>
/// Minimal process-wide logger. The WPF host redirects the sink to a rolling file;
/// tests and the default configuration write to the debugger output.
/// </summary>
public static class Log
{
    private static Action<string> _sink = message => System.Diagnostics.Debug.WriteLine(message);

    public static void SetSink(Action<string> sink)
    {
        ArgumentNullException.ThrowIfNull(sink);
        _sink = sink;
    }

    public static void Info(string category, string message)
    {
        try
        {
            _sink($"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff} [{category}] {message}");
        }
        catch
        {
            // Logging must never take the app down.
        }
    }
}
