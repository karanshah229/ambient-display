using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using AmbientDisplay.Core;

namespace AmbientDisplay.App.Platform;

/// <summary>
/// Advertises the LAN API as <c>_ambientdisplay._tcp</c> over mDNS / DNS-SD so the Android companion finds this PC
/// without a manual IP (the counterpart of <c>NWListener.Service</c> on macOS). Uses the DNS-SD API built into
/// Windows 10/11 (dnsapi.dll), so no Bonjour install is needed. Re-registers when the LAN address changes.
/// </summary>
internal sealed class MdnsAdvertiser : IDisposable
{
    public const string ServiceType = "_ambientdisplay._tcp";

    private const uint DnsQueryRequestVersion1 = 1;
    private const uint DnsRequestPending = 9506;

    private readonly string _instanceName;
    private readonly string _hostName;
    private readonly ushort _port;
    private readonly Dictionary<string, string> _txt;
    private readonly RegisterCompleteCallback _callback;
    private readonly IntPtr _callbackPointer;
    private readonly Lock _lock = new();
    private readonly Timer _debounce;

    private IntPtr _request;
    private IntPtr _instance;
    private IPAddress? _advertisedAddress;
    private bool _disposed;

    public MdnsAdvertiser(string instanceName, int port, IReadOnlyDictionary<string, string> txt)
    {
        _instanceName = Sanitize(instanceName);
        _hostName = Sanitize(Dns.GetHostName());
        _port = (ushort)port;
        _txt = new Dictionary<string, string>(txt);

        // The callback must stay alive for as long as Windows may call it.
        _callback = OnRegisterComplete;
        _callbackPointer = Marshal.GetFunctionPointerForDelegate(_callback);
        _debounce = new Timer(_ => Refresh(), null, Timeout.Infinite, Timeout.Infinite);
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void RegisterCompleteCallback(uint status, IntPtr queryContext, IntPtr instance);

    public string ServiceName => $"{_instanceName}.{ServiceType}.local";

    public IPAddress? AdvertisedAddress => _advertisedAddress;

    public void Start()
    {
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        Refresh();
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
        }

        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        _debounce.Dispose();
        lock (_lock)
        {
            Unregister();
        }
    }

    /// <summary>The IPv4 address and interface the phone can reach: an up, non-virtual adapter with a default gateway.</summary>
    internal static (IPAddress Address, int InterfaceIndex)? FindLanAddress()
    {
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up
                || nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
            {
                continue;
            }

            var props = nic.GetIPProperties();
            var hasGateway = props.GatewayAddresses.Any(g =>
                g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any));
            if (!hasGateway)
            {
                continue; // skips Hyper-V / WSL virtual switches
            }

            var address = props.UnicastAddresses
                .Select(u => u.Address)
                .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !a.ToString().StartsWith("169.254.", StringComparison.Ordinal));
            if (address is null)
            {
                continue;
            }

            var index = props.GetIPv4Properties()?.Index ?? 0;
            return (address, index);
        }

        return null;
    }

    private void OnNetworkChanged(object? sender, EventArgs e) =>
        _debounce.Change(TimeSpan.FromSeconds(3), Timeout.InfiniteTimeSpan); // address changes come in bursts

    private void Refresh()
    {
        lock (_lock)
        {
            if (_disposed)
            {
                return;
            }

            var lan = FindLanAddress();
            if (lan is null)
            {
                if (_advertisedAddress is not null)
                {
                    Log.Info("mDNS", "No LAN address; withdrawing advertisement.");
                    Unregister();
                }

                return;
            }

            if (lan.Value.Address.Equals(_advertisedAddress))
            {
                return;
            }

            Unregister();
            Register(lan.Value.Address, lan.Value.InterfaceIndex);
        }
    }

    private void Register(IPAddress address, int interfaceIndex)
    {
        var ip4 = BitConverter.ToUInt32(address.GetAddressBytes(), 0); // IP4_ADDRESS is in network byte order
        var keys = _txt.Keys.ToArray();
        var values = keys.Select(k => _txt[k]).ToArray();

        IntPtr instance;
        try
        {
            instance = DnsServiceConstructInstance(ServiceName, $"{_hostName}.local", ref ip4, IntPtr.Zero, _port, 0, 0, (uint)keys.Length, keys, values);
        }
        catch (EntryPointNotFoundException)
        {
            Log.Info("mDNS", "This Windows build has no DNS-SD API (needs Windows 10 1809+). The phone can still find the PC by subnet scan.");
            return;
        }

        if (instance == IntPtr.Zero)
        {
            Log.Info("mDNS", "DnsServiceConstructInstance failed.");
            return;
        }

        var request = new DNS_SERVICE_REGISTER_REQUEST
        {
            Version = DnsQueryRequestVersion1,
            InterfaceIndex = (uint)interfaceIndex,
            pServiceInstance = instance,
            pRegisterCompletionCallback = _callbackPointer,
            pQueryContext = IntPtr.Zero,
            hCredentials = IntPtr.Zero,
            unicastEnabled = 0,
        };

        // Windows keeps a pointer to the request until deregistration, so it lives in unmanaged memory.
        var requestPointer = Marshal.AllocHGlobal(Marshal.SizeOf<DNS_SERVICE_REGISTER_REQUEST>());
        Marshal.StructureToPtr(request, requestPointer, fDeleteOld: false);

        var status = DnsServiceRegister(requestPointer, IntPtr.Zero);
        if (status != DnsRequestPending)
        {
            Log.Info("mDNS", $"DnsServiceRegister failed with status {status}.");
            Marshal.FreeHGlobal(requestPointer);
            DnsServiceFreeInstance(instance);
            return;
        }

        _request = requestPointer;
        _instance = instance;
        _advertisedAddress = address;
        Log.Info("mDNS", $"Advertising {ServiceName} -> {address}:{_port} (interface {interfaceIndex}).");
    }

    private void Unregister()
    {
        if (_request == IntPtr.Zero)
        {
            _advertisedAddress = null;
            return;
        }

        var status = DnsServiceDeRegister(_request, IntPtr.Zero);
        if (status != DnsRequestPending)
        {
            Log.Info("mDNS", $"DnsServiceDeRegister returned {status}.");
        }

        // The goodbye packet is sent asynchronously; give it a moment before releasing the request it reads.
        var request = _request;
        var instance = _instance;
        _request = IntPtr.Zero;
        _instance = IntPtr.Zero;
        _advertisedAddress = null;
        _ = Task.Delay(TimeSpan.FromSeconds(5)).ContinueWith(_ =>
        {
            Marshal.FreeHGlobal(request);
            DnsServiceFreeInstance(instance);
        }, TaskScheduler.Default);
    }

    private void OnRegisterComplete(uint status, IntPtr queryContext, IntPtr instance)
    {
        if (status != 0)
        {
            Log.Info("mDNS", $"Service registration completed with status {status}.");
        }

        if (instance != IntPtr.Zero)
        {
            DnsServiceFreeInstance(instance); // the callback receives its own copy
        }
    }

    /// <summary>DNS labels: letters, digits and hyphens only, at most 63 characters.</summary>
    internal static string Sanitize(string label)
    {
        var chars = label.Select(c => char.IsAsciiLetterOrDigit(c) || c == '-' ? c : '-').ToArray();
        var clean = new string(chars).Trim('-');
        if (clean.Length == 0)
        {
            clean = "AmbientDisplay";
        }

        return clean.Length > 63 ? clean[..63] : clean;
    }

    // ------------------------------------------------------------ dnsapi.dll

    [StructLayout(LayoutKind.Sequential)]
    private struct DNS_SERVICE_REGISTER_REQUEST
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr pServiceInstance;
        public IntPtr pRegisterCompletionCallback;
        public IntPtr pQueryContext;
        public IntPtr hCredentials;
        public int unicastEnabled;
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr DnsServiceConstructInstance(
        string pServiceName,
        string pHostName,
        ref uint pIp4,
        IntPtr pIp6,
        ushort wPort,
        ushort wPriority,
        ushort wWeight,
        uint dwPropertiesCount,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] keys,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] values);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern void DnsServiceFreeInstance(IntPtr pInstance);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceRegister(IntPtr pRequest, IntPtr pCancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceDeRegister(IntPtr pRequest, IntPtr pCancel);
}
