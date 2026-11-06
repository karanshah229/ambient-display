using System.Security.Cryptography;
using System.Text;
using System.Windows.Threading;
using AmbientDisplay.Core;
using AmbientDisplay.Core.Display;
using Microsoft.Win32;
using static AmbientDisplay.App.Platform.NativeMethods;

namespace AmbientDisplay.App.Platform;

/// <summary>
/// Enumerates monitors with EnumDisplayMonitors (geometry, primary flag) and QueryDisplayConfig
/// (friendly name + device path). The display ID is a short hash of the monitor device path,
/// which is stable across reboots and display re-ordering (the Windows analogue of CGDisplay UUIDs).
/// </summary>
internal sealed class Win32DisplayProvider : IDisplayProvider, IDisposable
{
    private readonly Dispatcher _dispatcher;
    private readonly DispatcherTimer _debounce;
    private IReadOnlyList<DisplayInfo>? _cache;

    public Win32DisplayProvider(Dispatcher dispatcher)
    {
        _dispatcher = dispatcher;

        // Display changes arrive in bursts (one per monitor/mode); coalesce them.
        _debounce = new DispatcherTimer(TimeSpan.FromMilliseconds(750), DispatcherPriority.Normal, OnDebounceElapsed, dispatcher);
        _debounce.Stop();
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
    }

    public event EventHandler? DisplaysChanged;

    public IReadOnlyList<DisplayInfo> GetDisplays() => _cache ??= Enumerate();

    public void Dispose()
    {
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        _debounce.Stop();
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) =>
        _dispatcher.BeginInvoke(() =>
        {
            _cache = null;
            _debounce.Stop();
            _debounce.Start();
        });

    private void OnDebounceElapsed(object? sender, EventArgs e)
    {
        _debounce.Stop();
        _cache = null;
        DisplaysChanged?.Invoke(this, EventArgs.Empty);
    }

    internal static IReadOnlyList<DisplayInfo> Enumerate()
    {
        var targets = QueryTargetsByGdiName();
        var result = new List<DisplayInfo>();
        var index = 0;

        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hMonitor, IntPtr _, ref RECT _, IntPtr _) =>
        {
            index++;
            var info = new MONITORINFOEX { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<MONITORINFOEX>() };
            if (!GetMonitorInfo(hMonitor, ref info))
            {
                return true;
            }

            var gdiName = info.szDevice ?? $"DISPLAY{index}";
            targets.TryGetValue(gdiName, out var target);
            var stableKey = string.IsNullOrEmpty(target.DevicePath) ? gdiName : target.DevicePath;
            var name = string.IsNullOrWhiteSpace(target.FriendlyName)
                ? (index == 1 ? "Built-in Display" : $"Display {index}")
                : target.FriendlyName;

            result.Add(new DisplayInfo(
                Id: StableId(stableKey),
                Name: name,
                IsPrimary: (info.dwFlags & MONITORINFOF_PRIMARY) != 0,
                Width: info.rcMonitor.Right - info.rcMonitor.Left,
                Height: info.rcMonitor.Bottom - info.rcMonitor.Top));
            return true;
        }, IntPtr.Zero);

        // Primary display first, then enumeration order (mirrors NSScreen.screens[0] being the main screen).
        return result.OrderByDescending(d => d.IsPrimary).ToList();
    }

    /// <summary>Monitor bounds in physical pixels, keyed by display ID (used by the overlay presenter).</summary>
    internal static Dictionary<string, RECT> GetMonitorBounds()
    {
        var targets = QueryTargetsByGdiName();
        var bounds = new Dictionary<string, RECT>(StringComparer.OrdinalIgnoreCase);
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hMonitor, IntPtr _, ref RECT _, IntPtr _) =>
        {
            var info = new MONITORINFOEX { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<MONITORINFOEX>() };
            if (GetMonitorInfo(hMonitor, ref info) && info.szDevice is { } gdiName)
            {
                targets.TryGetValue(gdiName, out var target);
                var key = string.IsNullOrEmpty(target.DevicePath) ? gdiName : target.DevicePath;
                bounds[StableId(key)] = info.rcMonitor;
            }

            return true;
        }, IntPtr.Zero);
        return bounds;
    }

    private static string StableId(string key)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(key.ToUpperInvariant()));
        return Convert.ToHexString(hash, 0, 4).ToLowerInvariant();
    }

    private static Dictionary<string, (string FriendlyName, string DevicePath)> QueryTargetsByGdiName()
    {
        var map = new Dictionary<string, (string, string)>(StringComparer.OrdinalIgnoreCase);
        try
        {
            DISPLAYCONFIG_PATH_INFO[] paths;
            uint pathCount;
            int status;
            do
            {
                if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out var modeCount) != ERROR_SUCCESS)
                {
                    return map;
                }

                paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
                var modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
                status = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
            }
            while (status == ERROR_INSUFFICIENT_BUFFER);

            if (status != ERROR_SUCCESS)
            {
                return map;
            }

            for (var i = 0; i < pathCount; i++)
            {
                var path = paths[i];

                var source = new DISPLAYCONFIG_SOURCE_DEVICE_NAME();
                source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
                source.header.size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<DISPLAYCONFIG_SOURCE_DEVICE_NAME>();
                source.header.adapterId = path.sourceInfo.adapterId;
                source.header.id = path.sourceInfo.id;
                if (DisplayConfigGetDeviceInfo(ref source) != ERROR_SUCCESS || string.IsNullOrEmpty(source.viewGdiDeviceName))
                {
                    continue;
                }

                var target = new DISPLAYCONFIG_TARGET_DEVICE_NAME();
                target.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
                target.header.size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<DISPLAYCONFIG_TARGET_DEVICE_NAME>();
                target.header.adapterId = path.targetInfo.adapterId;
                target.header.id = path.targetInfo.id;
                if (DisplayConfigGetDeviceInfo(ref target) != ERROR_SUCCESS)
                {
                    continue;
                }

                // In clone mode several targets share one source; keep the first.
                map.TryAdd(source.viewGdiDeviceName, (target.monitorFriendlyDeviceName ?? string.Empty, target.monitorDevicePath ?? string.Empty));
            }
        }
        catch (Exception ex)
        {
            Log.Info("Displays", $"QueryDisplayConfig failed: {ex.Message}");
        }

        return map;
    }
}
