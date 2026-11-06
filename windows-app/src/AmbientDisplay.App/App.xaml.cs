using System.Diagnostics;
using System.Net.Http;
using System.Windows;
using System.Windows.Threading;
using AmbientDisplay.App.Platform;
using AmbientDisplay.App.UI;
using AmbientDisplay.App.UI.Overlay;
using AmbientDisplay.App.UI.Preferences;
using AmbientDisplay.Core;
using AmbientDisplay.Core.Cloud;
using AmbientDisplay.Core.Display;
using AmbientDisplay.Core.Server;
using AmbientDisplay.Core.Settings;
using AmbientDisplay.Core.State;

namespace AmbientDisplay.App;

/// <summary>Composition root. Runs as a tray-only app (no main window, no taskbar button).</summary>
public partial class App : Application
{
    private const string SingleInstanceMutexName = @"Local\AmbientDisplay.SingleInstance";

    private Mutex? _singleInstance;
    private DispatcherTimer? _tickTimer;
    private Win32DisplayProvider? _displayProvider;
    private Win32PowerManager? _power;
    private LocalApiServer? _server;
    private TrayIcon? _tray;
    private OverlayPresenter? _presenter;
    private MdnsAdvertiser? _mdns;
    private FirestoreCloudService? _firestore;

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private AppState? _appState;
    private DisplayCoordinator? _coordinator;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        if (e.Args.Length >= 2 && e.Args[0] == "--render-snapshots")
        {
            SnapshotRenderer.RenderAll(Path.GetFullPath(e.Args[1]));
            Shutdown();
            return;
        }

        _singleInstance = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out var createdNew);
        if (!createdNew)
        {
            // Another instance already owns port 8321 and the displays.
            _singleInstance.Dispose();
            _singleInstance = null;
            Shutdown();
            return;
        }

        var localData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AmbientDisplay");
        var logger = new FileLogger(Path.Combine(localData, "logs"));
        Log.SetSink(logger.Write);
        DispatcherUnhandledException += (_, args) =>
        {
            Log.Info("App", $"Unhandled UI exception: {args.Exception}");
            args.Handled = true;
        };

        var settingsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AmbientDisplay", "settings.json");
        var store = new JsonSettingsStore(settingsPath);

        _appState = new AppState(store);
        _displayProvider = new Win32DisplayProvider(Dispatcher);
        _power = new Win32PowerManager();
        _presenter = new OverlayPresenter(_appState, _displayProvider, Win32DisplayProvider.GetMonitorBounds);
        _coordinator = new DisplayCoordinator(_appState, _displayProvider, _presenter, _power);
        _presenter.Attach(_coordinator);
        var identity = new DeviceIdentity(store);
        var uiDispatcher = new WpfDispatcher(Dispatcher);

        // Cloud sync is optional: without %APPDATA%\AmbientDisplay\firebase.json (or FIREBASE_* env vars)
        // the PC works over local Wi-Fi only, exactly like the macOS app.
        var firebase = FirebaseConfig.Load();
        ICloudService cloud;
        if (firebase.IsConfigured)
        {
            _firestore = new FirestoreCloudService(
                firebase,
                identity,
                _appState,
                _coordinator,
                uiDispatcher,
                new DpapiSecretStore(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AmbientDisplay", "secrets")),
                store,
                Http,
                openBrowser: uri => Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }));
            cloud = _firestore;
        }
        else
        {
            Log.Info("App", $"Cloud sync disabled: no Firebase config at {FirebaseConfig.DefaultPath}.");
            cloud = new DisabledCloudService(identity);
        }

        var launchAtLogin = new LaunchAtLoginManager(store);
        launchAtLogin.Refresh(); // re-register if the exe moved since the user enabled it

        var displayProvider = _displayProvider;
        var appState = _appState;
        var preferences = new PreferencesWindowController(() => new PreferencesViewModel(
            appState,
            launchAtLogin,
            displayProvider,
            cloud,
            LocalApiServer.DefaultPort,
            advertisedServiceName: () => _mdns?.AdvertisedAddress is not null ? _mdns.ServiceName : null));

        // POST /api/preferences from the phone opens the window here, as on macOS.
        var router = new ApiRouter(uiDispatcher, _appState, _coordinator, _power, cloud, openPreferences: preferences.Show);
        _server = new LocalApiServer(router, LocalApiServer.DefaultPort);

        _tray = new TrayIcon(
            _appState,
            cloud,
            launchAtLogin,
            LocalApiServer.DefaultPort,
            openPreferences: preferences.Show,
            openLogFolder: () => Process.Start(new ProcessStartInfo(Path.GetDirectoryName(logger.FilePath)!) { UseShellExecute = true }),
            quit: Shutdown);

        // One heartbeat drives the countdown and canvas expiry (replaces the macOS per-object Timers).
        _tickTimer = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Normal, (_, _) =>
        {
            _appState.Tick();
            _coordinator.Tick();
        }, Dispatcher);
        _tickTimer.Start();

        Log.Info("App", $"Ambient Display for Windows starting (settings: {settingsPath}).");
        foreach (var display in _displayProvider.GetDisplays())
        {
            Log.Info("App", $"Display {display.Id}: {display.Name} {display.Width}x{display.Height}{(display.IsPrimary ? " (primary)" : string.Empty)}");
        }

        if (await _server.StartAsync())
        {
            // Let the phone find this PC without typing an IP (macOS: NWListener.Service / Bonjour).
            _mdns = new MdnsAdvertiser(
                instanceName: $"AmbientDisplay-{identity.DeviceName}",
                port: _server.BoundPort ?? LocalApiServer.DefaultPort,
                txt: new Dictionary<string, string>
                {
                    ["platform"] = "windows",
                    ["device_id"] = identity.DeviceId,
                    ["name"] = identity.DeviceName,
                    ["api"] = "1",
                });
            _mdns.Start();
        }

        if (_firestore is not null)
        {
            await _firestore.InitializeAsync(); // resumes a saved Google session, if any
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tickTimer?.Stop();
        if (_firestore is { } firestore)
        {
            // Mark the device offline and close listeners; off the UI thread, and never block exit for long.
            Task.Run(() => firestore.DisposeAsync().AsTask()).Wait(TimeSpan.FromSeconds(4));
        }

        _mdns?.Dispose();
        _tray?.Dispose();
        _presenter?.Dispose();
        _power?.Dispose();
        _displayProvider?.Dispose();
        _server?.StopAsync().GetAwaiter().GetResult();
        _singleInstance?.ReleaseMutex();
        _singleInstance?.Dispose();
        Log.Info("App", "Ambient Display application terminated.");
        base.OnExit(e);
    }
}
