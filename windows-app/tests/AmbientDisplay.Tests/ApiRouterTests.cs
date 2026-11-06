using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using AmbientDisplay.Core.Models;
using AmbientDisplay.Core.Server;

namespace AmbientDisplay.Tests;

/// <summary>Contract tests for the LAN API used by the Android companion (routes, codes and bodies match macOS).</summary>
public class ApiRouterTests
{
    private static byte[] Body(string json) => Encoding.UTF8.GetBytes(json);

    private static JsonElement Parse(ApiResponse response) => JsonDocument.Parse(response.Body).RootElement;

    [Fact]
    public async Task StatusReportsIdleByDefault()
    {
        var host = new TestHost();

        var response = await host.Router.HandleAsync("GET", "/api/status", []);
        var json = Parse(response);

        Assert.Equal(200, response.StatusCode);
        Assert.Equal("application/json", response.ContentType);
        Assert.Equal("idle", json.GetProperty("state").GetString());
        Assert.False(json.GetProperty("is_away_mode").GetBoolean());
        Assert.Equal(2, json.GetProperty("screens_count").GetInt32());
        Assert.False(json.GetProperty("power_assertion_active").GetBoolean());
        Assert.False(json.TryGetProperty("bedtime", out _)); // nil optionals are omitted
    }

    [Fact]
    public async Task SleepStartsSessionWithBedtimeAndDuration()
    {
        var host = new TestHost();
        var bedtime = host.Time.GetUtcNow().AddMinutes(-10).ToUnixTimeMilliseconds();

        var response = await host.Router.HandleAsync("POST", "/api/sleep",
            Body($"{{\"bedtime_epoch_ms\": {bedtime}, \"duration_minutes\": 480, \"reason\": \"auto\"}}"));

        Assert.Equal(200, response.StatusCode);
        Assert.Equal("{\"status\": \"success\", \"message\": \"Sleep session started\", \"duration_minutes\": 480.0}", response.BodyText);
        Assert.Equal(SessionState.Sleeping, host.App.State);
        Assert.Equal(bedtime, host.App.CurrentSession!.Bedtime.ToUnixTimeMilliseconds());
        Assert.True(host.Power.IsAsserted);

        var status = Parse(await host.Router.HandleAsync("GET", "/api/status", []));
        Assert.Equal("sleeping", status.GetProperty("state").GetString());
        Assert.Equal(470 * 60, status.GetProperty("remaining_seconds").GetDouble());
        Assert.Equal("7h 50m remaining", status.GetProperty("countdown_text").GetString());
    }

    [Fact]
    public async Task SleepWithoutBodyUsesDefaultDuration()
    {
        var host = new TestHost();
        host.App.DefaultSleepHours = 8;

        var response = await host.Router.HandleAsync("POST", "/api/sleep", []);

        Assert.Contains("\"duration_minutes\": 480.0", response.BodyText);
        Assert.Equal("remote_trigger", host.App.CurrentSession!.Reason);
    }

    [Fact]
    public async Task WakeTestAndAwayEndpoints()
    {
        var host = new TestHost();

        var test = await host.Router.HandleAsync("POST", "/api/test", Body("{\"duration_seconds\": 5}"));
        Assert.Equal("{\"status\": \"success\", \"message\": \"Test mode started\", \"duration_seconds\": 5}", test.BodyText);
        Assert.True(host.App.IsTestMode);

        var wake = await host.Router.HandleAsync("POST", "/api/wake", []);
        Assert.Equal(200, wake.StatusCode);
        Assert.Equal(SessionState.Idle, host.App.State);

        await host.Router.HandleAsync("POST", "/api/away", []); // no body toggles
        Assert.True(host.App.IsAwayMode);
        await host.Router.HandleAsync("POST", "/api/away", Body("{\"is_away_mode\": true}"));
        Assert.True(host.App.IsAwayMode);
        await host.Router.HandleAsync("POST", "/api/away", Body("{\"is_away_mode\": false}"));
        Assert.False(host.App.IsAwayMode);
    }

    [Fact]
    public async Task ConfigRoundTrip()
    {
        var host = new TestHost();

        var update = await host.Router.HandleAsync("POST", "/api/config",
            Body("{\"default_sleep_hours\": 8.5, \"sleep_window_start_hour\": 22, \"ambient_wake_color_hex\": \"#00FF00\"}"));
        Assert.Equal(200, update.StatusCode);

        var config = Parse(await host.Router.HandleAsync("GET", "/api/config", []));
        Assert.Equal(8.5, config.GetProperty("default_sleep_hours").GetDouble());
        Assert.Equal(22, config.GetProperty("sleep_window_start_hour").GetInt32());
        Assert.Equal(6, config.GetProperty("sleep_window_end_hour").GetInt32());
        Assert.Equal("#00FF00", config.GetProperty("ambient_wake_color_hex").GetString());
        Assert.True(config.GetProperty("auto_detect_inactivity").GetBoolean());

        var bad = await host.Router.HandleAsync("POST", "/api/config", Body("not json"));
        Assert.Equal(400, bad.StatusCode);
        Assert.Equal("{\"error\": \"Invalid JSON\"}", bad.BodyText);
    }

    [Fact]
    public async Task DisplaysListsMonitorsWithModes()
    {
        var host = new TestHost();
        host.App.SetDisplayIgnored("bbbb0002", ignored: true);

        var json = Parse(await host.Router.HandleAsync("GET", "/api/displays", []));
        var displays = json.GetProperty("displays");

        Assert.Equal(2, displays.GetArrayLength());
        Assert.Equal("aaaa0001", displays[0].GetProperty("id").GetString());
        Assert.True(displays[0].GetProperty("is_main").GetBoolean());
        Assert.Equal("idle", displays[0].GetProperty("active_mode").GetString());
        Assert.True(displays[1].GetProperty("is_ignored").GetBoolean());
    }

    [Fact]
    public async Task MessageValidationAndLifecycle()
    {
        var host = new TestHost();

        var missing = await host.Router.HandleAsync("POST", "/api/message", Body("{\"target_display_id\": \"all\"}"));
        Assert.Equal(400, missing.StatusCode);
        Assert.Contains("Expected { text, target_display_id?, duration_seconds? }", missing.BodyText);

        var empty = await host.Router.HandleAsync("POST", "/api/message", Body("{\"text\": \"   \"}"));
        Assert.Equal("{\"error\": \"Message text cannot be empty\"}", empty.BodyText);

        var shown = Parse(await host.Router.HandleAsync("POST", "/api/message", Body("{\"text\": \" Dinner is ready \", \"duration_seconds\": 60}")));
        Assert.Equal("Dinner is ready", shown.GetProperty("text").GetString());
        Assert.Equal(60, shown.GetProperty("remaining_seconds").GetInt32());

        var status = Parse(await host.Router.HandleAsync("GET", "/api/message/status", []));
        Assert.Equal(1, status.GetProperty("active_messages").GetArrayLength());

        var dismissed = await host.Router.HandleAsync("POST", "/api/message/dismiss", Body("{\"target_display_id\": \"all\"}"));
        Assert.Equal("{\"status\": \"success\", \"message\": \"Message dismissed on target: all\"}", dismissed.BodyText);
        Assert.False(host.Coordinator.HasActiveCanvases);
    }

    [Fact]
    public async Task CanvasAcceptsAliasesAndDefaults()
    {
        var host = new TestHost();

        var noTitle = await host.Router.HandleAsync("POST", "/api/canvas", Body("{\"type\": \"image\"}"));
        Assert.Equal(400, noTitle.StatusCode);
        Assert.Equal("{\"error\": \"Canvas title/text cannot be empty\"}", noTitle.BodyText);

        var canvas = Parse(await host.Router.HandleAsync("POST", "/api/canvas",
            Body("{\"type\": \"web\", \"text\": \"Grafana\", \"media_url\": \"https://example.com\", \"dismiss_policy\": \"phone_only\", \"target_display_id\": \"BBBB0002\"}")));
        Assert.Equal("webview", canvas.GetProperty("type").GetString());
        Assert.Equal("Grafana", canvas.GetProperty("title").GetString());
        Assert.Equal("phone_only", canvas.GetProperty("dismiss_policy").GetString());
        Assert.Equal("bbbb0002", canvas.GetProperty("target_display_id").GetString());
        Assert.Matches("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$", canvas.GetProperty("created_at").GetString());
        Assert.False(canvas.TryGetProperty("duration_seconds", out _));

        var unknownType = Parse(await host.Router.HandleAsync("POST", "/api/canvas", Body("{\"type\": \"hologram\", \"title\": \"x\"}")));
        Assert.Equal("billboard", unknownType.GetProperty("type").GetString());

        // Broadcasting to "all" replaces every earlier canvas, including the targeted one.
        var status = Parse(await host.Router.HandleAsync("GET", "/api/canvas/status", []));
        Assert.Equal(1, status.GetProperty("active_canvases").GetArrayLength());
        Assert.Equal("x", status.GetProperty("active_canvases")[0].GetProperty("title").GetString());

        var dismissed = await host.Router.HandleAsync("POST", "/api/canvas/dismiss", []);
        Assert.Equal("{\"status\": \"success\", \"message\": \"Canvas dismissed on target: all\"}", dismissed.BodyText);
    }

    [Fact]
    public async Task CloudEndpointsReportSignedOutDevice()
    {
        var host = new TestHost();

        var status = Parse(await host.Router.HandleAsync("GET", "/api/cloud/status", []));
        Assert.False(status.GetProperty("is_signed_in").GetBoolean());
        Assert.Equal("machine_karan_s_desktop_pc", status.GetProperty("device_id").GetString());
        Assert.Equal(0, status.GetProperty("registered_devices_count").GetInt32());

        var devices = await host.Router.HandleAsync("GET", "/api/cloud/devices", []);
        Assert.Equal("[]", devices.BodyText);

        var missingToken = await host.Router.HandleAsync("POST", "/api/cloud/auth", Body("{}"));
        Assert.Equal(400, missingToken.StatusCode);

        var auth = await host.Router.HandleAsync("POST", "/api/cloud/auth", Body("{\"id_token\": \"abc\"}"));
        Assert.Equal(401, auth.StatusCode);
        Assert.Equal("error", Parse(auth).GetProperty("status").GetString());

        var signOut = await host.Router.HandleAsync("POST", "/api/cloud/signout", []);
        Assert.Equal("{\"status\": \"signed_out\"}", signOut.BodyText);
    }

    [Fact]
    public async Task PreferencesOptionsIndexAndNotFound()
    {
        var host = new TestHost();

        await host.Router.HandleAsync("POST", "/api/preferences", []);
        Assert.Equal(1, host.PreferencesOpened);

        var options = await host.Router.HandleAsync("OPTIONS", "/anything", []);
        Assert.Equal(200, options.StatusCode);
        Assert.Equal("OK", options.BodyText);

        var index = await host.Router.HandleAsync("GET", "/", []);
        Assert.Equal("text/html", index.ContentType);
        Assert.Contains("Windows Node", index.BodyText);

        var missing = await host.Router.HandleAsync("GET", "/api/\"nope", []);
        Assert.Equal(404, missing.StatusCode);
        Assert.Equal("/api/\"nope", Parse(missing).GetProperty("path").GetString());

        var wrongMethod = await host.Router.HandleAsync("GET", "/api/sleep", []);
        Assert.Equal(404, wrongMethod.StatusCode);
    }

    [Fact]
    public async Task KestrelServerServesRouterOverHttp()
    {
        var host = new TestHost();
        await using var server = new LocalApiServer(host.Router, port: 0, bindAddress: IPAddress.Loopback);
        Assert.True(await server.StartAsync());

        using var client = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{server.BoundPort}") };

        var status = await client.GetAsync("/api/status");
        Assert.Equal(HttpStatusCode.OK, status.StatusCode);
        Assert.Equal("*", status.Headers.GetValues("Access-Control-Allow-Origin").Single());
        Assert.Equal("application/json", status.Content.Headers.ContentType!.MediaType);
        Assert.False(status.Headers.Contains("Server"));

        var canvas = await client.PostAsJsonAsync("/api/canvas", new { title = "Over the wire", duration_seconds = 15 });
        Assert.Equal(HttpStatusCode.OK, canvas.StatusCode);
        Assert.True(host.Coordinator.HasActiveCanvases);

        var notFound = await client.GetAsync("/nope?x=1");
        Assert.Equal(HttpStatusCode.NotFound, notFound.StatusCode);
        Assert.Contains("\"path\": \"/nope\"", await notFound.Content.ReadAsStringAsync());

        // A second server on the same port must fail gracefully, not throw.
        await using var clash = new LocalApiServer(host.Router, server.BoundPort!.Value, IPAddress.Loopback);
        Assert.False(await clash.StartAsync());
    }
}
