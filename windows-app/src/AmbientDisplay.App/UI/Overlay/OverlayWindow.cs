using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using static AmbientDisplay.App.Platform.NativeMethods;

namespace AmbientDisplay.App.UI.Overlay;

/// <summary>
/// Borderless, always-on-top, pure-black window covering exactly one monitor (the Windows analogue of the
/// macOS KeyCatchingWindow). Positioned in physical pixels so it is exact under per-monitor DPI.
/// Kept out of Alt+Tab and the taskbar. ESC, clicks and Alt+F4 are routed to the presenter.
/// </summary>
internal sealed class OverlayWindow : Window
{
    private RECT _bounds;
    private bool _allowClose;

    public OverlayWindow(string displayId, RECT bounds)
    {
        DisplayId = displayId;
        _bounds = bounds;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = true;
        Background = Brushes.Black;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Title = "Ambient Display";

        // Rough initial placement; SourceInitialized applies the exact physical-pixel bounds.
        Left = bounds.Left;
        Top = bounds.Top;
        Width = Math.Max(1, bounds.Right - bounds.Left);
        Height = Math.Max(1, bounds.Bottom - bounds.Top);

        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            var exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
            exStyle = (exStyle | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW;
            SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(exStyle));
            ApplyBounds();
        };
    }

    public string DisplayId { get; }

    /// <summary>ESC pressed while this window has keyboard focus.</summary>
    public event EventHandler? EscapePressed;

    /// <summary>Left click on the background (buttons handle their own clicks).</summary>
    public event EventHandler? BackgroundClicked;

    /// <summary>Alt+F4 or another close request not issued by the presenter.</summary>
    public event EventHandler? CloseRequested;

    public void UpdateBounds(RECT bounds)
    {
        _bounds = bounds;
        ApplyBounds();
    }

    /// <summary>Re-asserts top-most z-order (above the taskbar and other top-most windows).</summary>
    public void RaiseToTop(bool activate)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero)
        {
            return;
        }

        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW | (activate ? 0 : SWP_NOACTIVATE));
        if (activate)
        {
            Activate();
            SetForegroundWindow(hwnd);
            Focus();
            Keyboard.Focus(this);
        }
    }

    /// <summary>Closes the window for real (Alt+F4 is intercepted).</summary>
    public void CloseForReal()
    {
        _allowClose = true;
        if (Content is IDisposable disposable)
        {
            disposable.Dispose();
        }

        Content = null;
        Close();
    }

    public void SetContent(FrameworkElement content)
    {
        if (ReferenceEquals(Content, content))
        {
            return;
        }

        if (Content is IDisposable previous)
        {
            previous.Dispose();
        }

        Content = content;
    }

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            EscapePressed?.Invoke(this, EventArgs.Empty);
            return;
        }

        base.OnPreviewKeyDown(e);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (!e.Handled)
        {
            BackgroundClicked?.Invoke(this, EventArgs.Empty);
        }
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_allowClose)
        {
            // Alt+F4 must obey the dismiss policy (phone_only canvases stay up).
            e.Cancel = true;
            CloseRequested?.Invoke(this, EventArgs.Empty);
            return;
        }

        base.OnClosing(e);
    }

    private void ApplyBounds()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero)
        {
            return;
        }

        SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            _bounds.Left,
            _bounds.Top,
            _bounds.Right - _bounds.Left,
            _bounds.Bottom - _bounds.Top,
            SWP_NOACTIVATE);
    }
}
