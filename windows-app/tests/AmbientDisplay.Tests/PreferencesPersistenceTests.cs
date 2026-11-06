using AmbientDisplay.Core.Cloud;
using AmbientDisplay.Core.Settings;
using AmbientDisplay.Core.State;

namespace AmbientDisplay.Tests;

/// <summary>Port of macOS PreferencesPersistenceTests.swift, against the JSON settings file.</summary>
public sealed class PreferencesPersistenceTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "AmbientDisplayTests", Guid.NewGuid().ToString("N"));

    private string SettingsPath => Path.Combine(_directory, "settings.json");

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }

    [Fact]
    public void PreferencesPersistAcrossSimulatedAppRestart()
    {
        var firstRun = new AppState(new JsonSettingsStore(SettingsPath))
        {
            DefaultSleepHours = 8.5,
            InactivityOffsetMinutes = 45.0,
            AutoDetectInactivityOffset = false,
            SleepWindowStartHour = 22,
            SleepWindowEndHour = 7,
            AutoPushWindowStartHour = 20,
            AutoPushWindowEndHour = 22,
            AmbientNightColorHex = "#112233",
            AmbientDawnColorHex = "#445566",
            AmbientWakeColorHex = "#778899",
            ShowCountdownInTray = false,
            IsAwayMode = true,
        };
        Assert.NotNull(firstRun);

        var secondRun = new AppState(new JsonSettingsStore(SettingsPath));
        Assert.Equal(8.5, secondRun.DefaultSleepHours);
        Assert.Equal(8.5 * 60.0, secondRun.DefaultSleepMinutes);
        Assert.Equal(45.0, secondRun.InactivityOffsetMinutes);
        Assert.False(secondRun.AutoDetectInactivityOffset);
        Assert.Equal(22, secondRun.SleepWindowStartHour);
        Assert.Equal(7, secondRun.SleepWindowEndHour);
        Assert.Equal(20, secondRun.AutoPushWindowStartHour);
        Assert.Equal(22, secondRun.AutoPushWindowEndHour);
        Assert.Equal("#112233", secondRun.AmbientNightColorHex);
        Assert.Equal("#445566", secondRun.AmbientDawnColorHex);
        Assert.Equal("#778899", secondRun.AmbientWakeColorHex);
        Assert.False(secondRun.ShowCountdownInTray);
        Assert.True(secondRun.IsAwayMode);
    }

    [Fact]
    public void IgnoredDisplaysPersistById()
    {
        var firstRun = new AppState(new JsonSettingsStore(SettingsPath));
        firstRun.SetDisplayIgnored("8b8d3282", ignored: true);
        firstRun.SetDisplayIgnored("0000beef", ignored: true);
        firstRun.SetDisplayIgnored("0000beef", ignored: false);

        var secondRun = new AppState(new JsonSettingsStore(SettingsPath));
        Assert.True(secondRun.IsDisplayIgnored("8b8d3282"));
        Assert.True(secondRun.IsDisplayIgnored("8B8D3282")); // IDs are case-insensitive
        Assert.False(secondRun.IsDisplayIgnored("0000beef"));
    }

    [Fact]
    public void LegacySleepMinutesMigrateToHours()
    {
        var store = new JsonSettingsStore(SettingsPath);
        store.Set(PreferenceKeys.LegacyDefaultSleepMinutes, 540.0);

        var app = new AppState(new JsonSettingsStore(SettingsPath));

        Assert.Equal(9.0, app.DefaultSleepHours);
    }

    [Fact]
    public void DefaultAmbientThemeColorsAndReset()
    {
        var fresh = new AppState(JsonSettingsStore.InMemory());
        Assert.Equal("#D95926", fresh.AmbientNightColorHex);
        Assert.Equal("#FA7268", fresh.AmbientDawnColorHex);
        Assert.Equal("#FFD000", fresh.AmbientWakeColorHex);

        fresh.AmbientNightColorHex = "#000000";
        fresh.AmbientDawnColorHex = "#111111";
        fresh.AmbientWakeColorHex = "#222222";
        fresh.ResetAmbientDefaults();

        Assert.Equal("#D95926", fresh.AmbientNightColorHex);
        Assert.Equal("#FA7268", fresh.AmbientDawnColorHex);
        Assert.Equal("#FFD000", fresh.AmbientWakeColorHex);
    }

    [Fact]
    public void LegacyDawnAndWakeColorsUpgradeToSunriseDefaults()
    {
        var store = new JsonSettingsStore(SettingsPath);
        store.Set(PreferenceKeys.AmbientDawnColorHex, "#FFBF66");
        store.Set(PreferenceKeys.AmbientWakeColorHex, "#FFB800");

        var app = new AppState(new JsonSettingsStore(SettingsPath));

        Assert.Equal("#FA7268", app.AmbientDawnColorHex);
        Assert.Equal("#FFD000", app.AmbientWakeColorHex);
    }

    [Fact]
    public void CorruptSettingsFileFallsBackToDefaults()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(SettingsPath, "{ not json");

        var app = new AppState(new JsonSettingsStore(SettingsPath));

        Assert.Equal(7.5, app.DefaultSleepHours);
    }

    [Fact]
    public void CloudPreferencesApplyWithoutEchoingBack()
    {
        var app = new AppState(JsonSettingsStore.InMemory());
        var pushes = 0;
        app.CloudPreferencesChanged += (_, _) => pushes++;

        app.ApplyCloudPreferences(new Dictionary<string, object?>
        {
            ["defaultSleepHours"] = 8L,
            ["sleepWindowStartHour"] = 23.0,
            ["autoDetectInactivity"] = false,
            ["ambientWakeColorHex"] = "#ABCDEF",
        });

        Assert.Equal(8.0, app.DefaultSleepHours);
        Assert.Equal(23, app.SleepWindowStartHour);
        Assert.False(app.AutoDetectInactivityOffset);
        Assert.Equal("#ABCDEF", app.AmbientWakeColorHex);
        Assert.Equal(0, pushes);

        app.DefaultSleepHours = 6;
        Assert.Equal(1, pushes);
        Assert.Equal(6.0, app.GetCloudPreferences()["defaultSleepHours"]);
    }

    [Fact]
    public void DeviceIdMatchesMacOsGenerationRuleAndPersists()
    {
        Assert.Equal("machine_karan_s_desktop_pc", DeviceIdentity.GenerateDeviceId("Karan's Desktop PC"));
        Assert.Equal("machine_a_very_long_workstat", DeviceIdentity.GenerateDeviceId("A Very Long Workstation Name"));

        var store = new JsonSettingsStore(SettingsPath);
        var first = new DeviceIdentity(store, "Studio-PC").DeviceId;
        var renamed = new DeviceIdentity(new JsonSettingsStore(SettingsPath), "Renamed-PC").DeviceId;

        Assert.Equal("machine_studio_pc", first);
        Assert.Equal(first, renamed);
    }
}
