using System.Text;
using System.Text.Json;
using AmbientDisplay.Core.Cloud;
using AmbientDisplay.Core.Display;
using AmbientDisplay.Core.Models;
using AmbientDisplay.Core.State;

namespace AmbientDisplay.Core.Server;

public sealed record ApiResponse(int StatusCode, string ContentType, byte[] Body)
{
    public string BodyText => Encoding.UTF8.GetString(Body);

    public static ApiResponse Json(int statusCode, string json) => new(statusCode, "application/json", Encoding.UTF8.GetBytes(json));

    public static ApiResponse Json<T>(T payload) => Json(200, ApiJson.Serialize(payload));
}

/// <summary>
/// Transport-independent request router for the LAN API. Routes, status codes and bodies mirror
/// macOS <c>LocalHTTPServer.swift</c> so the Android companion works unchanged.
/// State is touched only through <see cref="IUiDispatcher"/>.
/// </summary>
public sealed class ApiRouter
{
    private static readonly TimeSpan CloudAuthTimeout = TimeSpan.FromSeconds(5);

    private readonly IUiDispatcher _ui;
    private readonly AppState _app;
    private readonly DisplayCoordinator _displays;
    private readonly IPowerManager _power;
    private readonly ICloudService _cloud;
    private readonly Action? _openPreferences;

    public ApiRouter(
        IUiDispatcher ui,
        AppState app,
        DisplayCoordinator displays,
        IPowerManager power,
        ICloudService cloud,
        Action? openPreferences = null)
    {
        _ui = ui;
        _app = app;
        _displays = displays;
        _power = power;
        _cloud = cloud;
        _openPreferences = openPreferences;
    }

    public async Task<ApiResponse> HandleAsync(string method, string path, byte[] body)
    {
        method = method.ToUpperInvariant();

        // CORS preflight for any path.
        if (method == "OPTIONS")
        {
            return new ApiResponse(200, "text/plain", "OK"u8.ToArray());
        }

        return (method, path) switch
        {
            ("GET", "/api/status") => await GetStatusAsync(),
            ("POST", "/api/sleep") => await PostSleepAsync(body),
            ("POST", "/api/wake") => await PostWakeAsync(),
            ("POST", "/api/test") => await PostTestAsync(body),
            ("POST", "/api/away") => await PostAwayAsync(body),
            ("POST", "/api/preferences") => await PostPreferencesAsync(),
            ("GET", "/api/config") => await GetConfigAsync(),
            ("POST", "/api/config") => await PostConfigAsync(body),
            ("GET", "/api/displays") => await GetDisplaysAsync(),
            ("POST", "/api/message") => await PostMessageAsync(body),
            ("POST", "/api/message/dismiss") => await PostDismissAsync(body, "Message"),
            ("GET", "/api/message/status") => await GetMessageStatusAsync(),
            ("POST", "/api/canvas") => await PostCanvasAsync(body),
            ("POST", "/api/canvas/dismiss") => await PostDismissAsync(body, "Canvas"),
            ("GET", "/api/canvas/status") => await GetCanvasStatusAsync(),
            ("GET", "/api/cloud/status") => await GetCloudStatusAsync(),
            ("GET", "/api/cloud/devices") => await GetCloudDevicesAsync(),
            ("POST", "/api/cloud/auth") => await PostCloudAuthAsync(body),
            ("POST", "/api/cloud/oauth-start") => await PostCloudOAuthStartAsync(),
            ("POST", "/api/cloud/signout") => await PostCloudSignOutAsync(),
            ("GET", "/") => new ApiResponse(200, "text/html", Encoding.UTF8.GetBytes(IndexHtml)),
            _ => ApiResponse.Json(404, $"{{\"error\": \"Not Found\", \"path\": \"{ApiJson.Escape(path)}\"}}"),
        };
    }

    // ---------------------------------------------------------------- Sleep session

    private Task<ApiResponse> GetStatusAsync() => _ui.InvokeAsync(() =>
    {
        var session = _app.CurrentSession;
        var at = _app.LastUpdated;
        return ApiResponse.Json(new StatusResponsePayload(
            State: _app.State.ToWireValue(),
            IsAwayMode: _app.IsAwayMode,
            IsTestMode: _app.IsTestMode,
            Bedtime: session?.FormattedBedtime(),
            TargetWakeTime: session?.FormattedTargetTime(),
            RemainingSeconds: session?.TimeRemainingSeconds(at),
            CountdownText: session?.FormattedCountdown(at),
            ScreensCount: _displays.DisplayCount,
            PowerAssertionActive: _power.IsAsserted));
    });

    private Task<ApiResponse> PostSleepAsync(byte[] body)
    {
        var request = ApiJson.TryDeserialize<SleepRequestPayload>(body);
        DateTimeOffset? bedtime = request?.BedtimeEpochMs is double epochMs && epochMs > 0
            ? DateTimeOffset.FromUnixTimeMilliseconds((long)epochMs)
            : null;
        var reason = request?.Reason ?? "remote_trigger";

        return _ui.InvokeAsync(() =>
        {
            var durationMinutes = request?.DurationMinutes ?? _app.DefaultSleepMinutes;
            _app.StartSleep(bedtime, durationMinutes, reason);
            return ApiResponse.Json(200, $"{{\"status\": \"success\", \"message\": \"Sleep session started\", \"duration_minutes\": {ApiJson.SwiftDouble(durationMinutes)}}}");
        });
    }

    private Task<ApiResponse> PostWakeAsync() => _ui.InvokeAsync(() =>
    {
        _app.StopSleep();
        return ApiResponse.Json(200, "{\"status\": \"success\", \"message\": \"Sleep session stopped\"}");
    });

    private Task<ApiResponse> PostTestAsync(byte[] body)
    {
        var duration = ApiJson.TryDeserialize<TestRequestPayload>(body)?.DurationSeconds ?? 10;
        return _ui.InvokeAsync(() =>
        {
            _app.StartTestMode(duration);
            return ApiResponse.Json(200, $"{{\"status\": \"success\", \"message\": \"Test mode started\", \"duration_seconds\": {duration}}}");
        });
    }

    private Task<ApiResponse> PostAwayAsync(byte[] body)
    {
        var request = ApiJson.TryDeserialize<AwayRequestPayload>(body);
        return _ui.InvokeAsync(() =>
        {
            if (request?.IsAwayMode is { } isAway)
            {
                _app.IsAwayMode = isAway;
            }
            else
            {
                _app.ToggleAwayMode();
            }

            return ApiResponse.Json(200, "{\"status\": \"success\", \"message\": \"Away mode toggled\"}");
        });
    }

    private Task<ApiResponse> PostPreferencesAsync() => _ui.InvokeAsync(() =>
    {
        _openPreferences?.Invoke();
        return ApiResponse.Json(200, "{\"status\": \"success\", \"message\": \"Preferences opened\"}");
    });

    // ---------------------------------------------------------------- Config

    private Task<ApiResponse> GetConfigAsync() => _ui.InvokeAsync(() => ApiResponse.Json(new ConfigResponsePayload(
        DefaultSleepHours: _app.DefaultSleepHours,
        SleepWindowStartHour: _app.SleepWindowStartHour,
        SleepWindowEndHour: _app.SleepWindowEndHour,
        AutoPushWindowStartHour: _app.AutoPushWindowStartHour,
        AutoPushWindowEndHour: _app.AutoPushWindowEndHour,
        InactivityOffsetMinutes: _app.InactivityOffsetMinutes,
        AutoDetectInactivity: _app.AutoDetectInactivityOffset,
        IsAwayMode: _app.IsAwayMode,
        AmbientNightColorHex: _app.AmbientNightColorHex,
        AmbientDawnColorHex: _app.AmbientDawnColorHex,
        AmbientWakeColorHex: _app.AmbientWakeColorHex)));

    private async Task<ApiResponse> PostConfigAsync(byte[] body)
    {
        var request = ApiJson.TryDeserialize<ConfigUpdateRequestPayload>(body);
        if (request is null)
        {
            return ApiResponse.Json(400, "{\"error\": \"Invalid JSON\"}");
        }

        await _ui.InvokeAsync(() =>
        {
            if (request.DefaultSleepHours is { } hours) _app.DefaultSleepHours = hours;
            if (request.SleepWindowStartHour is { } sleepStart) _app.SleepWindowStartHour = sleepStart;
            if (request.SleepWindowEndHour is { } sleepEnd) _app.SleepWindowEndHour = sleepEnd;
            if (request.AutoPushWindowStartHour is { } pushStart) _app.AutoPushWindowStartHour = pushStart;
            if (request.AutoPushWindowEndHour is { } pushEnd) _app.AutoPushWindowEndHour = pushEnd;
            if (request.InactivityOffsetMinutes is { } offset) _app.InactivityOffsetMinutes = offset;
            if (request.AutoDetectInactivity is { } autoDetect) _app.AutoDetectInactivityOffset = autoDetect;
            if (request.IsAwayMode is { } away) _app.IsAwayMode = away;
            if (request.AmbientNightColorHex is { } night) _app.AmbientNightColorHex = night;
            if (request.AmbientDawnColorHex is { } dawn) _app.AmbientDawnColorHex = dawn;
            if (request.AmbientWakeColorHex is { } wake) _app.AmbientWakeColorHex = wake;
        });

        return ApiResponse.Json(200, "{\"status\": \"success\", \"message\": \"Configuration updated\"}");
    }

    // ---------------------------------------------------------------- Displays, messages, canvases

    private Task<ApiResponse> GetDisplaysAsync() =>
        _ui.InvokeAsync(() => ApiResponse.Json(new DisplaysResponsePayload(_displays.GetConnectedDisplays())));

    private async Task<ApiResponse> PostMessageAsync(byte[] body)
    {
        var request = ApiJson.TryDeserialize<PostMessageRequestPayload>(body);
        if (request is null)
        {
            return ApiResponse.Json(400, "{\"error\": \"Invalid request payload. Expected { text, target_display_id?, duration_seconds? }\"}");
        }

        var text = request.Text.Trim();
        if (text.Length == 0)
        {
            return ApiResponse.Json(400, "{\"error\": \"Message text cannot be empty\"}");
        }

        return await _ui.InvokeAsync(() =>
            ApiResponse.Json(_displays.ShowMessage(text, request.TargetDisplayId ?? "all", request.DurationSeconds)));
    }

    private async Task<ApiResponse> PostCanvasAsync(byte[] body)
    {
        var request = ApiJson.TryDeserialize<PostCanvasRequestPayload>(body);
        if (request is null)
        {
            return ApiResponse.Json(400, "{\"error\": \"Invalid request payload. Expected { type?, title?, subtitle?, text?, media_url?, theme?, dismiss_policy?, target_display_id?, duration_seconds? }\"}");
        }

        var title = (request.Title ?? request.Text ?? string.Empty).Trim();
        if (title.Length == 0)
        {
            return ApiResponse.Json(400, "{\"error\": \"Canvas title/text cannot be empty\"}");
        }

        return await _ui.InvokeAsync(() => ApiResponse.Json(_displays.ShowCanvas(
            type: CanvasWire.ParseType(request.Type),
            title: title,
            subtitle: request.Subtitle?.Trim(),
            mediaUrl: request.MediaUrl,
            theme: request.Theme,
            dismissPolicy: CanvasWire.ParsePolicy(request.DismissPolicy),
            targetDisplayId: request.TargetDisplayId ?? "all",
            durationSeconds: request.DurationSeconds)));
    }

    private async Task<ApiResponse> PostDismissAsync(byte[] body, string noun)
    {
        var target = ApiJson.TryDeserialize<DismissRequestPayload>(body)?.TargetDisplayId ?? "all";
        await _ui.InvokeAsync(() => _displays.DismissCanvas(target));
        return ApiResponse.Json(200, $"{{\"status\": \"success\", \"message\": \"{noun} dismissed on target: {ApiJson.Escape(target)}\"}}");
    }

    private Task<ApiResponse> GetMessageStatusAsync() =>
        _ui.InvokeAsync(() => ApiResponse.Json(new MessageStatusResponsePayload(_displays.GetActiveMessagesList())));

    private Task<ApiResponse> GetCanvasStatusAsync() =>
        _ui.InvokeAsync(() => ApiResponse.Json(new CanvasStatusResponsePayload(_displays.GetActiveCanvasesList())));

    // ---------------------------------------------------------------- Cloud

    private Task<ApiResponse> GetCloudStatusAsync() => _ui.InvokeAsync(() =>
    {
        var status = _cloud.GetStatus();
        var dict = new Dictionary<string, object>
        {
            ["is_signed_in"] = status.User is not null,
            ["device_id"] = status.DeviceId,
            ["device_name"] = status.DeviceName,
            ["is_connected"] = status.IsConnected,
            ["registered_devices_count"] = status.RegisteredDevicesCount,
        };

        if (status.SyncError is { } error)
        {
            dict["sync_error"] = error;
        }

        if (status.LastSyncTime is { } lastSync)
        {
            dict["last_sync_time"] = ApiJson.Iso8601(lastSync);
        }

        if (status.User is { } user)
        {
            dict["uid"] = user.Uid;
            dict["email"] = user.Email ?? string.Empty;
            dict["display_name"] = user.DisplayName ?? string.Empty;
        }

        return ApiResponse.Json(200, JsonSerializer.Serialize(dict));
    });

    private Task<ApiResponse> GetCloudDevicesAsync() => _ui.InvokeAsync(() =>
        ApiResponse.Json(200, JsonSerializer.Serialize(_cloud.RegisteredDevices, new JsonSerializerOptions
        {
            WriteIndented = true,
            DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
        })));

    private async Task<ApiResponse> PostCloudAuthAsync(byte[] body)
    {
        string? idToken = null;
        try
        {
            if (body.Length > 0)
            {
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.ValueKind == JsonValueKind.Object
                    && doc.RootElement.TryGetProperty("id_token", out var token)
                    && token.ValueKind == JsonValueKind.String)
                {
                    idToken = token.GetString();
                }
            }
        }
        catch (JsonException)
        {
        }

        if (string.IsNullOrEmpty(idToken))
        {
            return ApiResponse.Json(400, "{\"error\": \"Missing id_token\"}");
        }

        string message;
        try
        {
            using var cts = new CancellationTokenSource(CloudAuthTimeout);
            var signIn = await _ui.InvokeAsync(() => _cloud.SignInWithGoogleIdTokenAsync(idToken, cts.Token));
            await signIn.WaitAsync(cts.Token);
            return ApiResponse.Json(200, "{\"status\": \"authenticated\"}");
        }
        catch (OperationCanceledException)
        {
            message = string.Empty; // macOS returns an empty message on timeout.
        }
        catch (Exception ex)
        {
            message = ex.Message;
        }

        return ApiResponse.Json(401, $"{{\"status\": \"error\", \"message\": \"{ApiJson.Escape(message)}\"}}");
    }

    private Task<ApiResponse> PostCloudOAuthStartAsync() => _ui.InvokeAsync(() =>
    {
        _cloud.StartGoogleOAuthFlow();
        return ApiResponse.Json(200, "{\"status\": \"oauth_started\", \"message\": \"Browser opened for Google sign in\"}");
    });

    private Task<ApiResponse> PostCloudSignOutAsync() => _ui.InvokeAsync(() =>
    {
        _cloud.SignOut();
        return ApiResponse.Json(200, "{\"status\": \"signed_out\"}");
    });

    private const string IndexHtml = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Ambient Display — Windows Node</title>
            <style>
                body { font-family: "Segoe UI", system-ui, sans-serif; background: #121212; color: #f0f0f0; text-align: center; padding: 40px; }
                .card { background: #1e1e1e; max-width: 500px; margin: 0 auto; padding: 24px; border-radius: 16px; box-shadow: 0 4px 20px rgba(0,0,0,0.5); }
                h1 { color: #ff9f0a; }
                button { background: #32d74b; color: #000; border: none; padding: 12px 24px; font-size: 16px; border-radius: 8px; cursor: pointer; margin: 8px; font-weight: bold; }
                button.stop { background: #ff453a; color: #fff; }
                pre { text-align: left; background: #000; padding: 12px; border-radius: 8px; overflow-x: auto; color: #30d158; }
            </style>
        </head>
        <body>
            <div class="card">
                <h1>Ambient Display</h1>
                <p>Native Windows Server &amp; Multi-Monitor Display Node</p>
                <div>
                    <button onclick="fetch('/api/test', {method:'POST'}).then(load)">Test Preview (10s)</button>
                    <button onclick="fetch('/api/sleep', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({duration_minutes:450})}).then(load)">Start 7.5h Sleep</button>
                    <button class="stop" onclick="fetch('/api/wake', {method:'POST'}).then(load)">Stop / Wake</button>
                </div>
                <h3>Current Status</h3>
                <pre id="status">Loading...</pre>
            </div>
            <script>
                function load() {
                    fetch('/api/status').then(r => r.json()).then(data => {
                        document.getElementById('status').innerText = JSON.stringify(data, null, 2);
                    });
                }
                load();
                setInterval(load, 2000);
            </script>
        </body>
        </html>
        """;
}
