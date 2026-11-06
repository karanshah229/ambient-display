using System.Runtime.InteropServices;
using System.Windows.Interop;
using AmbientDisplay.Core;
using static AmbientDisplay.App.Platform.NativeMethods;

namespace AmbientDisplay.App.Platform;

/// <summary>
/// System-wide ESC hotkey, registered only while overlays cover every monitor.
/// Windows' foreground lock usually stops a background app (woken by a network request) from taking
/// keyboard focus, so a full-screen overlay would otherwise ignore ESC. When at least one monitor is
/// uncovered the user may be typing elsewhere, so the hotkey is released and only focused overlays see ESC.
/// </summary>
internal sealed class GlobalEscapeHotkey : IDisposable
{
    private const int HotkeyId = 0xAD01;

    private readonly HwndSource _source;
    private readonly Action _onEscape;
    private bool _registered;

    public GlobalEscapeHotkey(Action onEscape)
    {
        _onEscape = onEscape;
        _source = new HwndSource(new HwndSourceParameters("AmbientDisplayHotkeys") { ParentWindow = HWND_MESSAGE });
        _source.AddHook(WndProc);
    }

    public bool IsRegistered => _registered;

    public void SetEnabled(bool enabled)
    {
        if (enabled == _registered)
        {
            return;
        }

        if (enabled)
        {
            _registered = RegisterHotKey(_source.Handle, HotkeyId, MOD_NOREPEAT, VK_ESCAPE);
            if (!_registered)
            {
                Log.Info("Hotkey", $"Could not register global ESC (error {Marshal.GetLastWin32Error()}); ESC works only when an overlay has focus.");
            }
        }
        else
        {
            UnregisterHotKey(_source.Handle, HotkeyId);
            _registered = false;
        }
    }

    public void Dispose()
    {
        SetEnabled(false);
        _source.RemoveHook(WndProc);
        _source.Dispose();
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_HOTKEY && wParam.ToInt32() == HotkeyId)
        {
            handled = true;
            _onEscape();
        }

        return IntPtr.Zero;
    }
}
