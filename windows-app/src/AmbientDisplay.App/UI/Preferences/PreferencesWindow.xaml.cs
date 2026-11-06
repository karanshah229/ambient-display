using System.ComponentModel;
using System.Windows;

namespace AmbientDisplay.App.UI.Preferences;

/// <summary>The Preferences window. Only one instance is open at a time (see <see cref="PreferencesWindowController"/>).</summary>
public partial class PreferencesWindow
{
    internal PreferencesWindow(PreferencesViewModel viewModel)
    {
        InitializeComponent();
        DataContext = viewModel;
    }

    internal int SelectedTab
    {
        get => ((System.Windows.Controls.TabControl)Content).SelectedIndex;
        set => ((System.Windows.Controls.TabControl)Content).SelectedIndex = value;
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // Commit a hex colour still being edited before the window goes away.
        if (System.Windows.Input.Keyboard.FocusedElement is System.Windows.Controls.TextBox box)
        {
            box.GetBindingExpression(System.Windows.Controls.TextBox.TextProperty)?.UpdateSource();
        }

        base.OnClosing(e);
    }

    protected override void OnClosed(EventArgs e)
    {
        (DataContext as IDisposable)?.Dispose();
        base.OnClosed(e);
    }
}

/// <summary>Opens the Preferences window, or brings the existing one to the front (macOS PreferencesWindowController).</summary>
internal sealed class PreferencesWindowController(Func<PreferencesViewModel> createViewModel)
{
    private PreferencesWindow? _window;

    public void Show()
    {
        if (_window is null)
        {
            _window = new PreferencesWindow(createViewModel());
            _window.Closed += (_, _) => _window = null;
            _window.Show();
        }

        if (_window.WindowState == WindowState.Minimized)
        {
            _window.WindowState = WindowState.Normal;
        }

        _window.Activate();
    }
}
