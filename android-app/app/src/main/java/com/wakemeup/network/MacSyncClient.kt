package com.wakemeup.network

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class MacSyncClient(private val context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("WakeMeUpPrefs", Context.MODE_PRIVATE)

    private val client = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .writeTimeout(5, TimeUnit.SECONDS)
        .build()

    var macHost: String
        get() = prefs.getString("mac_host", "192.168.1.3") ?: "192.168.1.3"
        set(value) = prefs.edit().putString("mac_host", value).apply()

    var macPort: Int
        get() = prefs.getInt("mac_port", 8321)
        set(value) = prefs.edit().putInt("mac_port", value).apply()

    private val baseUrl: String
        get() = "http://$macHost:$macPort"

    suspend fun sendSleepEvent(
        bedtimeEpochMs: Long,
        durationMinutes: Double = 450.0,
        reason: String = "auto"
    ): Result<String> = withContext(Dispatchers.IO) {
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

    suspend fun sendWakeEvent(): Result<String> = withContext(Dispatchers.IO) {
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

    suspend fun sendTestEvent(durationSeconds: Int = 10): Result<String> = withContext(Dispatchers.IO) {
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

    suspend fun sendAwayEvent(isAway: Boolean): Result<String> = withContext(Dispatchers.IO) {
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

    suspend fun fetchStatus(): Result<String> = withContext(Dispatchers.IO) {
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
