using System.Windows.Threading;
using AmbientDisplay.Core.Display;

namespace AmbientDisplay.App.Platform;

/// <summary>Marshals Core calls from Kestrel threads onto the WPF UI thread.</summary>
internal sealed class WpfDispatcher(Dispatcher dispatcher) : IUiDispatcher
{
    public Task<T> InvokeAsync<T>(Func<T> func) =>
        dispatcher.CheckAccess() ? Task.FromResult(func()) : dispatcher.InvokeAsync(func).Task;

    public Task InvokeAsync(Action action)
    {
        if (dispatcher.CheckAccess())
        {
            action();
            return Task.CompletedTask;
        }

        return dispatcher.InvokeAsync(action).Task;
    }
}
