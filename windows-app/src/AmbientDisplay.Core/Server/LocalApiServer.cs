using System.Net;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace AmbientDisplay.Core.Server;

/// <summary>
/// Hosts <see cref="ApiRouter"/> on Kestrel. Binds 0.0.0.0:8321 by default so the Android companion can
/// reach it over Wi-Fi. Kestrel needs no URL ACL (unlike HttpListener), so this runs without admin rights.
/// </summary>
public sealed class LocalApiServer : IAsyncDisposable
{
    public const int DefaultPort = 8321;
    private const long MaxBodyBytes = 1024 * 1024;

    private readonly ApiRouter _router;
    private readonly IPAddress _bindAddress;
    private readonly int _port;
    private WebApplication? _app;

    public LocalApiServer(ApiRouter router, int port = DefaultPort, IPAddress? bindAddress = null)
    {
        _router = router;
        _port = port;
        _bindAddress = bindAddress ?? IPAddress.Any;
    }

    /// <summary>Actual listening port (useful when constructed with port 0).</summary>
    public int? BoundPort { get; private set; }

    public bool IsRunning => _app is not null;

    public async Task<bool> StartAsync()
    {
        if (_app is not null)
        {
            return true;
        }

        var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions
        {
            ApplicationName = typeof(LocalApiServer).Assembly.GetName().Name,
            ContentRootPath = AppContext.BaseDirectory,
        });
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(options =>
        {
            options.AddServerHeader = false;
            options.Limits.MaxRequestBodySize = MaxBodyBytes;
            options.Listen(_bindAddress, _port);
        });

        var app = builder.Build();
        app.Run(HandleAsync);

        try
        {
            await app.StartAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            Log.Info("LocalApiServer", $"Could not start listener on port {_port}: {ex.Message}");
            await app.DisposeAsync().ConfigureAwait(false);
            return false;
        }

        var addresses = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()?.Addresses;
        var first = addresses?.FirstOrDefault();
        BoundPort = first is not null && Uri.TryCreate(first, UriKind.Absolute, out var uri) ? uri.Port : _port;
        _app = app;
        Log.Info("LocalApiServer", $"Running and listening on http://{_bindAddress}:{BoundPort}");
        return true;
    }

    public async Task StopAsync()
    {
        var app = _app;
        _app = null;
        if (app is null)
        {
            return;
        }

        try
        {
            await app.StopAsync().ConfigureAwait(false);
        }
        finally
        {
            await app.DisposeAsync().ConfigureAwait(false);
            Log.Info("LocalApiServer", "Stopped.");
        }
    }

    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

    private async Task HandleAsync(HttpContext context)
    {
        var request = context.Request;
        byte[] body;
        using (var buffer = new MemoryStream())
        {
            await request.Body.CopyToAsync(buffer, context.RequestAborted).ConfigureAwait(false);
            body = buffer.ToArray();
        }

        Log.Info("LocalApiServer", $"{request.Method} {request.Path} from {context.Connection.RemoteIpAddress} (body: {body.Length} bytes)");

        ApiResponse result;
        try
        {
            result = await _router.HandleAsync(request.Method, request.Path.Value ?? "/", body).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            Log.Info("LocalApiServer", $"Unhandled error for {request.Method} {request.Path}: {ex}");
            result = ApiResponse.Json(500, $"{{\"error\": \"Internal Server Error\", \"message\": \"{ApiJson.Escape(ex.Message)}\"}}");
        }

        var response = context.Response;
        response.StatusCode = result.StatusCode;
        response.ContentType = result.ContentType;
        response.ContentLength = result.Body.Length;
        response.Headers["Access-Control-Allow-Origin"] = "*";
        response.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS";
        response.Headers["Access-Control-Allow-Headers"] = "Content-Type";
        response.Headers.Connection = "close";
        await response.Body.WriteAsync(result.Body, context.RequestAborted).ConfigureAwait(false);
    }
}
