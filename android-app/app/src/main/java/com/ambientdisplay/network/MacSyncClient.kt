package com.ambientdisplay.network

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
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class MacSyncClient(private val context: Context) {

    private val prefs: SharedPreferences = run {
        val newPrefs = context.getSharedPreferences("AmbientDisplayPrefs", Context.MODE_PRIVATE)
        val oldPrefs = context.getSharedPreferences("AmbientDisplayPrefs", Context.MODE_PRIVATE)
        if (oldPrefs.all.isNotEmpty() && newPrefs.all.isEmpty()) {
            val editor = newPrefs.edit()
            for ((k, v) in oldPrefs.all) {
                when (v) {
                    is Boolean -> editor.putBoolean(k, v)
                    is Float -> editor.putFloat(k, v)
                    is Int -> editor.putInt(k, v)
                    is Long -> editor.putLong(k, v)
                    is String -> editor.putString(k, v)
                }
            }
            editor.apply()
        }
        newPrefs
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(3, TimeUnit.SECONDS)
        .readTimeout(3, TimeUnit.SECONDS)
        .writeTimeout(3, TimeUnit.SECONDS)
        .build()

    var macHost: String
        get() = prefs.getString("mac_host", "") ?: ""
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
        val multicastLock = wifiManager?.createMulticastLock("AmbientDisplayNsdLock")?.apply {
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
                        if (serviceInfo.serviceType.contains("_ambientdisplay") || serviceInfo.serviceType.contains("_ambientdisplay")) {
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
                    nsdManager.discoverServices("_ambientdisplay._tcp", NsdManager.PROTOCOL_DNS_SD, listener)
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

    data class AppConfig(
        val defaultSleepHours: Double = 7.5,
        val sleepWindowStartHour: Int = 21,
        val sleepWindowEndHour: Int = 6,
        val autoPushWindowStartHour: Int = 21,
        val autoPushWindowEndHour: Int = 23,
        val inactivityOffsetMinutes: Double = 30.0,
        val autoDetectInactivity: Boolean = true,
        val isAwayMode: Boolean = false,
        val ambientNightColorHex: String = "#D95926",
        val ambientDawnColorHex: String = "#FA7268",
        val ambientWakeColorHex: String = "#FFD000"
    )

    suspend fun fetchConfig(): Result<AppConfig> = executeWithAutoDiscovery {
        withContext(Dispatchers.IO) {
            try {
                val request = Request.Builder()
                    .url("$baseUrl/api/config")
                    .get()
                    .build()

                client.newCall(request).execute().use { response ->
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: "{}"
                        val obj = JSONObject(body)
                        val config = AppConfig(
                            defaultSleepHours = obj.optDouble("default_sleep_hours", 7.5),
                            sleepWindowStartHour = obj.optInt("sleep_window_start_hour", 21),
                            sleepWindowEndHour = obj.optInt("sleep_window_end_hour", 6),
                            autoPushWindowStartHour = obj.optInt("auto_push_window_start_hour", 21),
                            autoPushWindowEndHour = obj.optInt("auto_push_window_end_hour", 23),
                            inactivityOffsetMinutes = obj.optDouble("inactivity_offset_minutes", 30.0),
                            autoDetectInactivity = obj.optBoolean("auto_detect_inactivity", true),
                            isAwayMode = obj.optBoolean("is_away_mode", false),
                            ambientNightColorHex = obj.optString("ambient_night_color_hex", "#D95926"),
                            ambientDawnColorHex = obj.optString("ambient_dawn_color_hex", "#FA7268"),
                            ambientWakeColorHex = obj.optString("ambient_wake_color_hex", "#FFD000")
                        )
                        Result.success(config)
                    } else {
                        Result.failure(Exception("HTTP ${response.code}"))
                    }
                }
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }

    suspend fun sendConfig(config: AppConfig): Result<String> = executeWithAutoDiscovery {
        withContext(Dispatchers.IO) {
            try {
                val json = JSONObject().apply {
                    put("default_sleep_hours", config.defaultSleepHours)
                    put("sleep_window_start_hour", config.sleepWindowStartHour)
                    put("sleep_window_end_hour", config.sleepWindowEndHour)
                    put("auto_push_window_start_hour", config.autoPushWindowStartHour)
                    put("auto_push_window_end_hour", config.autoPushWindowEndHour)
                    put("inactivity_offset_minutes", config.inactivityOffsetMinutes)
                    put("auto_detect_inactivity", config.autoDetectInactivity)
                    put("is_away_mode", config.isAwayMode)
                    put("ambient_night_color_hex", config.ambientNightColorHex)
                    put("ambient_dawn_color_hex", config.ambientDawnColorHex)
                    put("ambient_wake_color_hex", config.ambientWakeColorHex)
                }
                val body = json.toString().toRequestBody("application/json".toMediaType())
                val request = Request.Builder()
                    .url("$baseUrl/api/config")
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

    data class DisplayInfo(
        val id: String,
        val name: String,
        val isMain: Boolean,
        val width: Int,
        val height: Int,
        val activeMode: String,
        val isIgnored: Boolean
    )

    suspend fun fetchDisplays(): Result<List<DisplayInfo>> = executeWithAutoDiscovery {
        withContext(Dispatchers.IO) {
            try {
                val request = Request.Builder()
                    .url("$baseUrl/api/displays")
                    .get()
                    .build()

                client.newCall(request).execute().use { response ->
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: "{}"
                        val obj = JSONObject(body)
                        val array = obj.optJSONArray("displays") ?: JSONArray()
                        val list = mutableListOf<DisplayInfo>()
                        for (i in 0 until array.length()) {
                            val d = array.getJSONObject(i)
                            list.add(
                                DisplayInfo(
                                    id = d.optString("id", ""),
                                    name = d.optString("name", "Display $i"),
                                    isMain = d.optBoolean("is_main", false),
                                    width = d.optInt("width", 0),
                                    height = d.optInt("height", 0),
                                    activeMode = d.optString("active_mode", "idle"),
                                    isIgnored = d.optBoolean("is_ignored", false)
                                )
                            )
                        }
                        Result.success(list)
                    } else {
                        Result.failure(Exception("HTTP ${response.code}"))
                    }
                }
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }

    suspend fun sendMessage(
        text: String,
        targetDisplayId: String = "all",
        durationSeconds: Int? = null
    ): Result<String> = executeWithAutoDiscovery {
        withContext(Dispatchers.IO) {
            try {
                val json = JSONObject().apply {
                    put("text", text)
                    put("target_display_id", targetDisplayId)
                    if (durationSeconds != null && durationSeconds > 0) {
                        put("duration_seconds", durationSeconds)
                    }
                }
                val body = json.toString().toRequestBody("application/json".toMediaType())
                val request = Request.Builder()
                    .url("$baseUrl/api/message")
                    .post(body)
                    .build()

                client.newCall(request).execute().use { response ->
                    if (response.isSuccessful) {
                        Result.success(response.body?.string() ?: "OK")
                    } else {
                        Result.failure(Exception("HTTP ${response.code}: ${response.body?.string()}"))
                    }
                }
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }

    suspend fun dismissMessage(targetDisplayId: String = "all"): Result<String> = executeWithAutoDiscovery {
        withContext(Dispatchers.IO) {
            try {
                val json = JSONObject().apply {
                    put("target_display_id", targetDisplayId)
                }
                val body = json.toString().toRequestBody("application/json".toMediaType())
                val request = Request.Builder()
                    .url("$baseUrl/api/message/dismiss")
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

    suspend fun sendCanvas(
        type: String = "billboard",
        title: String,
        subtitle: String? = null,
        mediaUrl: String? = null,
        theme: String? = null,
        dismissPolicy: String = "esc_any",
        targetDisplayId: String = "all",
        durationSeconds: Int? = null
    ): Result<String> = executeWithAutoDiscovery {
        withContext(Dispatchers.IO) {
            try {
                val json = JSONObject().apply {
                    put("type", type)
                    put("title", title)
                    if (!subtitle.isNullOrBlank()) put("subtitle", subtitle)
                    if (!mediaUrl.isNullOrBlank()) put("media_url", mediaUrl)
                    if (!theme.isNullOrBlank()) put("theme", theme)
                    put("dismiss_policy", dismissPolicy)
                    put("target_display_id", targetDisplayId)
                    if (durationSeconds != null && durationSeconds > 0) {
                        put("duration_seconds", durationSeconds)
                    }
                }
                val body = json.toString().toRequestBody("application/json".toMediaType())
                val request = Request.Builder()
                    .url("$baseUrl/api/canvas")
                    .post(body)
                    .build()

                client.newCall(request).execute().use { response ->
                    if (response.isSuccessful) {
                        Result.success(response.body?.string() ?: "OK")
                    } else {
                        Result.failure(Exception("HTTP ${response.code}: ${response.body?.string()}"))
                    }
                }
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }

    suspend fun dismissCanvas(targetDisplayId: String = "all"): Result<String> = executeWithAutoDiscovery {
        withContext(Dispatchers.IO) {
            try {
                val json = JSONObject().apply {
                    put("target_display_id", targetDisplayId)
                }
                val body = json.toString().toRequestBody("application/json".toMediaType())
                val request = Request.Builder()
                    .url("$baseUrl/api/canvas/dismiss")
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
}

