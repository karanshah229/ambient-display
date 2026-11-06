using System.Runtime.InteropServices;
using AmbientDisplay.Core;
using AmbientDisplay.Core.Display;
using static AmbientDisplay.App.Platform.NativeMethods;

namespace AmbientDisplay.App.Platform;

/// <summary>
/// Windows equivalent of the macOS IOPMAssertion / ProcessInfo.beginActivity pair:
/// a power request with DisplayRequired + SystemRequired. Active requests are visible in
/// <c>powercfg /requests</c> (elevated) under DISPLAY and SYSTEM with the reason string.
/// </summary>
internal sealed class Win32PowerManager : IPowerManager, IDisposable
{
    private static readonly IntPtr InvalidHandle = new(-1);
    private readonly Lock _lock = new();
    private IntPtr _request = IntPtr.Zero;

    public bool IsAsserted { get; private set; }

    public void Acquire(string reason = "Ambient Display Active Sleep Countdown")
    {
        lock (_lock)
        {
            // Wake displays first in case they are already in standby.
            WakeDisplays();

            if (IsAsserted)
            {
                return;
            }

            var context = new REASON_CONTEXT
            {
                Version = POWER_REQUEST_CONTEXT_VERSION,
                Flags = POWER_REQUEST_CONTEXT_SIMPLE_STRING,
                SimpleReasonString = reason,
            };

            var handle = PowerCreateRequest(ref context);
            if (handle == IntPtr.Zero || handle == InvalidHandle)
            {
                Log.Info("Power", $"Warning: PowerCreateRequest failed (error {Marshal.GetLastWin32Error()}).");
                return;
            }

            var display = PowerSetRequest(handle, POWER_REQUEST_TYPE.PowerRequestDisplayRequired);
            var system = PowerSetRequest(handle, POWER_REQUEST_TYPE.PowerRequestSystemRequired);
            if (!display && !system)
            {
                Log.Info("Power", $"Warning: PowerSetRequest failed (error {Marshal.GetLastWin32Error()}).");
                CloseHandle(handle);
                return;
            }

            _request = handle;
            IsAsserted = true;
            Log.Info("Power", "Power requests acquired (display + system). Displays and system will not idle-sleep.");
        }
    }

    public void Release()
    {
        lock (_lock)
        {
            if (!IsAsserted)
            {
                return;
            }

            PowerClearRequest(_request, POWER_REQUEST_TYPE.PowerRequestDisplayRequired);
            PowerClearRequest(_request, POWER_REQUEST_TYPE.PowerRequestSystemRequired);
            CloseHandle(_request);
            _request = IntPtr.Zero;
            IsAsserted = false;
            Log.Info("Power", "Power requests released. System and display idle sleep restored.");
        }
    }

    /// <summary>Resets the display idle timer and nudges input so monitors in standby power up.</summary>
    public void WakeDisplays()
    {
        SetThreadExecutionState(EXECUTION_STATE.ES_DISPLAY_REQUIRED | EXECUTION_STATE.ES_SYSTEM_REQUIRED);

        var inputs = new[]
        {
            new INPUT { type = INPUT_MOUSE, mi = new MOUSEINPUT { dx = 1, dy = 0, dwFlags = MOUSEEVENTF_MOVE } },
            new INPUT { type = INPUT_MOUSE, mi = new MOUSEINPUT { dx = -1, dy = 0, dwFlags = MOUSEEVENTF_MOVE } },
        };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    public void Dispose() => Release();
}
