package com.wakemeup.network

import android.content.Context
import android.content.SharedPreferences
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class MacSyncClient(private val context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("WakeMeUpPrefs", Context.MODE_PRIVATE)

    private val client = OkHttpClient.Builder()
        .connectTimeout(3, TimeUnit.SECONDS)
        .readTimeout(3, TimeUnit.SECONDS)
        .writeTimeout(3, TimeUnit.SECONDS)
        .build()

    var macHost: String
        get() = prefs.getString("mac_host", "192.168.1.3") ?: "192.168.1.3"
        set(value) = prefs.edit().putString("mac_host", value).apply()

    var macPort: Int
        get() = prefs.getInt("mac_port", 8321)
        set(value) = prefs.edit().putInt("mac_port", value).apply()

    private val baseUrl: String
        get() = "http://$macHost:$macPort"

    private suspend fun <T> executeWithAutoDiscovery(block: suspend () -> Result<T>): Result<T> {
        val initialResult = block()
        if (initialResult.isSuccess) {
            return initialResult
        }

        // If call failed due to network unreachable / wrong IP, attempt auto-discovery
        val discoveryResult = autoDiscoverMac()
        if (discoveryResult.isSuccess) {
            // Retry once on the newly discovered IP
            return block()
        }

        return initialResult
    }

    suspend fun autoDiscoverMac(timeoutMs: Long = 3000): Result<String> = withContext(Dispatchers.IO) {
        // Step 1: Probe current cached IP quickly
        if (probeServer(macHost, macPort, timeoutMs = 400)) {
            return@withContext Result.success(macHost)
        }

        // Step 2 & 3: Run Bonjour NSD and Subnet Scan concurrently
        coroutineScope {
            val nsdDeferred = async { discoverViaBonjour(timeoutMs) }
            val scanDeferred = async { discoverViaSubnetScan() }

            // Whichever finishes first with a valid IP wins
            val nsdResult = nsdDeferred.await()
            if (nsdResult != null) {
                macHost = nsdResult
                return@coroutineScope Result.success(nsdResult)
            }

            val scanResult = scanDeferred.await()
            if (scanResult != null) {
                macHost = scanResult
                return@coroutineScope Result.success(scanResult)
            }

            Result.failure(Exception("MacBook Air not found via Bonjour or Subnet scan on port $macPort"))
        }
    }

    private suspend fun discoverViaBonjour(timeoutMs: Long): String? = withContext(Dispatchers.IO) {
        val nsdManager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return@withContext null
        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val multicastLock = wifiManager?.createMulticastLock("WakeMeUpNsdLock")?.apply {
            setReferenceCounted(true)
            acquire()
        }

        try {
            withTimeoutOrNull(timeoutMs) {
                var discoveredIp: String? = null
                val isDone = AtomicBoolean(false)

                val listener = object : NsdManager.DiscoveryListener {
                    override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {}
                    override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {}
                    override fun onDiscoveryStarted(serviceType: String?) {}
                    override fun onDiscoveryStopped(serviceType: String?) {}

                    override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                        if (isDone.get()) return
                        if (serviceInfo.serviceType.contains("_wakemeup")) {
                            try {
                                nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                                    override fun onResolveFailed(info: NsdServiceInfo?, code: Int) {}
                                    override fun onServiceResolved(info: NsdServiceInfo) {
                                        val host = info.host?.hostAddress
                                        if (host != null && !host.contains(":")) {
                                            discoveredIp = host
                                            isDone.set(true)
                                        }
                                    }
                                })
                            } catch (_: Exception) {}
                        }
                    }

                    override fun onServiceLost(serviceInfo: NsdServiceInfo?) {}
                }

                try {
                    nsdManager.discoverServices("_wakemeup._tcp", NsdManager.PROTOCOL_DNS_SD, listener)
                    while (!isDone.get()) {
                        delay(100)
                    }
                } finally {
                    try { nsdManager.stopServiceDiscovery(listener) } catch (_: Exception) {}
                }
                discoveredIp
            }
        } finally {
            try { multicastLock?.release() } catch (_: Exception) {}
        }
    }

    private suspend fun discoverViaSubnetScan(): String? = withContext(Dispatchers.IO) {
        val localIp = getLocalWifiIpAddress() ?: return@withContext null
        val parts = localIp.split(".")
        if (parts.size != 4) return@withContext null
        val subnetPrefix = "${parts[0]}.${parts[1]}.${parts[2]}."

        coroutineScope {
            val deferreds = (1..254).map { i ->
                async {
                    val candidateIp = "$subnetPrefix$i"
                    if (probeServer(candidateIp, macPort, timeoutMs = 350)) {
                        candidateIp
                    } else null
                }
            }
            deferreds.awaitAll().firstOrNull { it != null }
        }
    }

    private fun probeServer(ip: String, port: Int, timeoutMs: Int): Boolean {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(ip, port), timeoutMs)
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun getLocalWifiIpAddress(): String? {
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces() ?: return null
            for (intf in interfaces) {
                if (intf.isLoopback || !intf.isUp) continue
                val addrs = intf.inetAddresses
                for (addr in addrs) {
                    if (!addr.isLoopbackAddress && addr is Inet4Address) {
                        val host = addr.hostAddress
                        if (host != null && (host.startsWith("192.168.") || host.startsWith("10.") || host.startsWith("172."))) {
                            return host
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        return null
    }

    suspend fun sendSleepEvent(
        bedtimeEpochMs: Long,
        durationMinutes: Double = 450.0,
        reason: String = "auto"
    ): Result<String> = executeWithAutoDiscovery {
        withContext(Dispatchers.IO) {
            try {
                val json = JSONObject().apply {
                    put("bedtime_epoch_ms", bedtimeEpochMs.toDouble())
                    put("duration_minutes", durationMinutes)
                    put("reason", reason)
                }
                val body = json.toString().toRequestBody("application/json".toMediaType())
                val request = Request.Builder()
                    .url("$baseUrl/api/sleep")
                    .post(body)
                    .build()

                client.newCall(request).execute().use { response ->
                    if (response.isSuccessful) {
                        Result.success(response.body?.string() ?: "OK")
                    } else {
                        Result.failure(Exception("HTTP ${response.code}: ${response.message}"))
                    }
                }
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }

    suspend fun sendWakeEvent(): Result<String> = executeWithAutoDiscovery {
        withContext(Dispatchers.IO) {
            try {
                val body = "{}".toRequestBody("application/json".toMediaType())
                val request = Request.Builder()
                    .url("$baseUrl/api/wake")
                    .post(body)
                    .build()

                client.newCall(request).execute().use { response ->
                    if (response.isSuccessful) {
                        Result.success(response.body?.string() ?: "OK")
                    } else {
                        Result.failure(Exception("HTTP ${response.code}"))
                    }
                }
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }

    suspend fun sendTestEvent(durationSeconds: Int = 10): Result<String> = executeWithAutoDiscovery {
        withContext(Dispatchers.IO) {
            try {
                val json = JSONObject().apply {
                    put("duration_seconds", durationSeconds)
                }
                val body = json.toString().toRequestBody("application/json".toMediaType())
                val request = Request.Builder()
                    .url("$baseUrl/api/test")
                    .post(body)
                    .build()

                client.newCall(request).execute().use { response ->
                    if (response.isSuccessful) {
                        Result.success(response.body?.string() ?: "OK")
                    } else {
                        Result.failure(Exception("HTTP ${response.code}"))
                    }
                }
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }

    suspend fun sendAwayEvent(isAway: Boolean): Result<String> = executeWithAutoDiscovery {
        withContext(Dispatchers.IO) {
            try {
                val json = JSONObject().apply {
                    put("is_away_mode", isAway)
                }
                val body = json.toString().toRequestBody("application/json".toMediaType())
                val request = Request.Builder()
                    .url("$baseUrl/api/away")
                    .post(body)
                    .build()

                client.newCall(request).execute().use { response ->
                    if (response.isSuccessful) {
                        Result.success(response.body?.string() ?: "OK")
                    } else {
                        Result.failure(Exception("HTTP ${response.code}"))
                    }
                }
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }

    suspend fun fetchStatus(): Result<String> = executeWithAutoDiscovery {
        withContext(Dispatchers.IO) {
            try {
                val request = Request.Builder()
                    .url("$baseUrl/api/status")
                    .get()
                    .build()

                client.newCall(request).execute().use { response ->
                    if (response.isSuccessful) {
                        Result.success(response.body?.string() ?: "{}")
                    } else {
                        Result.failure(Exception("HTTP ${response.code}"))
                    }
                }
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }
}
