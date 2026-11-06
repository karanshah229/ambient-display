namespace AmbientDisplay.App.Platform;

/// <summary>Appends log lines to %LOCALAPPDATA%\AmbientDisplay\logs\ambient-display.log (rolled at 5 MB).</summary>
internal sealed class FileLogger
{
    private const long MaxBytes = 5 * 1024 * 1024;
    private readonly Lock _lock = new();

    public FileLogger(string directory)
    {
        Directory.CreateDirectory(directory);
        FilePath = Path.Combine(directory, "ambient-display.log");
    }

    public string FilePath { get; }

    public void Write(string line)
    {
        lock (_lock)
        {
            try
            {
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > MaxBytes)
                {
                    File.Move(FilePath, FilePath + ".1", overwrite: true);
                }

                File.AppendAllText(FilePath, line + Environment.NewLine);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        System.Diagnostics.Debug.WriteLine(line);
    }
}
