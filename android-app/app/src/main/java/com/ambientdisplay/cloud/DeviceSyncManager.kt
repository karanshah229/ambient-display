package com.ambientdisplay.cloud

import android.content.Context
import android.os.Build
import android.provider.Settings
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import kotlinx.coroutines.tasks.await
import java.util.Date

data class CloudDevice(
    val deviceId: String,
    val deviceName: String,
    val deviceType: String,
    val status: String,
    val lastSeen: Timestamp? = null,
    val activeCanvasTitle: String? = null
) {
    val isOnline: Boolean
        get() {
            if (status != "online") return false
            val seen = lastSeen?.toDate()?.time ?: return false
            // Active if heartbeat within last 90 seconds
            val now = System.currentTimeMillis()
            return (now - seen) < 90_000L
        }
}

class DeviceSyncManager(private val context: Context) {
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance()
    private val auth: FirebaseAuth = FirebaseAuth.getInstance()
    private var devicesListener: ListenerRegistration? = null
    private var preferencesListener: ListenerRegistration? = null

    val deviceId: String by lazy {
        val androidId = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: "phone"
        "mobile_$androidId"
    }

    val deviceName: String by lazy {
        "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"
    }

    fun registerCurrentDevice() {
        val uid = auth.currentUser?.uid ?: return
        val docRef = firestore.collection("users").document(uid).collection("devices").document(deviceId)
        val data = hashMapOf(
            "deviceId" to deviceId,
            "deviceName" to deviceName,
            "deviceType" to "mobile",
            "status" to "online",
            "lastSeen" to Timestamp(Date())
        )
        docRef.set(data, com.google.firebase.firestore.SetOptions.merge())
    }

    fun startListeningToPreferences(onPreferencesUpdated: (com.ambientdisplay.network.MacSyncClient.AppConfig) -> Unit) {
        stopListeningToPreferences()
        val uid = auth.currentUser?.uid ?: return
        preferencesListener = firestore.collection("users").document(uid)
            .addSnapshotListener { snapshot, error ->
                if (error != null || snapshot == null || !snapshot.exists()) return@addSnapshotListener
                val prefsMap = snapshot.get("preferences") as? Map<*, *> ?: return@addSnapshotListener

                val defaultSleepHours = (prefsMap["defaultSleepHours"] as? Number)?.toDouble() ?: 7.5
                val sleepWindowStartHour = (prefsMap["sleepWindowStartHour"] as? Number)?.toInt() ?: 21
                val sleepWindowEndHour = (prefsMap["sleepWindowEndHour"] as? Number)?.toInt() ?: 6
                val autoPushWindowStartHour = (prefsMap["autoPushWindowStartHour"] as? Number)?.toInt() ?: 21
                val autoPushWindowEndHour = (prefsMap["autoPushWindowEndHour"] as? Number)?.toInt() ?: 23
                val inactivityOffsetMinutes = (prefsMap["inactivityOffsetMinutes"] as? Number)?.toDouble() ?: 30.0
                val autoDetectInactivity = prefsMap["autoDetectInactivity"] as? Boolean ?: true
                val isAwayMode = prefsMap["isAwayMode"] as? Boolean ?: false
                val ambientNightColorHex = prefsMap["ambientNightColorHex"] as? String ?: "#D95926"
                val ambientDawnColorHex = prefsMap["ambientDawnColorHex"] as? String ?: "#FA7268"
                val ambientWakeColorHex = prefsMap["ambientWakeColorHex"] as? String ?: "#FFD000"

                val config = com.ambientdisplay.network.MacSyncClient.AppConfig(
                    defaultSleepHours = defaultSleepHours,
                    sleepWindowStartHour = sleepWindowStartHour,
                    sleepWindowEndHour = sleepWindowEndHour,
                    autoPushWindowStartHour = autoPushWindowStartHour,
                    autoPushWindowEndHour = autoPushWindowEndHour,
                    inactivityOffsetMinutes = inactivityOffsetMinutes,
                    autoDetectInactivity = autoDetectInactivity,
                    isAwayMode = isAwayMode,
                    ambientNightColorHex = ambientNightColorHex,
                    ambientDawnColorHex = ambientDawnColorHex,
                    ambientWakeColorHex = ambientWakeColorHex
                )
                onPreferencesUpdated(config)
            }
    }

    fun stopListeningToPreferences() {
        preferencesListener?.remove()
        preferencesListener = null
    }

    fun savePreferencesToCloud(config: com.ambientdisplay.network.MacSyncClient.AppConfig) {
        val uid = auth.currentUser?.uid ?: return
        val prefsMap = hashMapOf<String, Any>(
            "defaultSleepHours" to config.defaultSleepHours,
            "sleepWindowStartHour" to config.sleepWindowStartHour,
            "sleepWindowEndHour" to config.sleepWindowEndHour,
            "autoPushWindowStartHour" to config.autoPushWindowStartHour,
            "autoPushWindowEndHour" to config.autoPushWindowEndHour,
            "inactivityOffsetMinutes" to config.inactivityOffsetMinutes,
            "autoDetectInactivity" to config.autoDetectInactivity,
            "isAwayMode" to config.isAwayMode,
            "ambientNightColorHex" to config.ambientNightColorHex,
            "ambientDawnColorHex" to config.ambientDawnColorHex,
            "ambientWakeColorHex" to config.ambientWakeColorHex
        )
        val data = hashMapOf<String, Any>(
            "userId" to uid,
            "preferences" to prefsMap,
            "updatedAt" to Timestamp(Date())
        )
        firestore.collection("users").document(uid).set(data, com.google.firebase.firestore.SetOptions.merge())
    }

    fun startListeningToDevices(onDevicesUpdated: (List<CloudDevice>) -> Unit) {
        stopListening()
        val uid = auth.currentUser?.uid ?: return
        devicesListener = firestore.collection("users").document(uid).collection("devices")
            .addSnapshotListener { snapshot, error ->
                if (error != null || snapshot == null) return@addSnapshotListener
                val devices = snapshot.documents.mapNotNull { doc ->
                    val id = doc.getString("deviceId") ?: doc.id
                    val name = doc.getString("deviceName") ?: "Unnamed Device"
                    val type = doc.getString("deviceType") ?: "unknown"
                    val status = doc.getString("status") ?: "offline"
                    val lastSeen = doc.getTimestamp("lastSeen")
                    val activeCanvasMap = doc.get("activeCanvas") as? Map<*, *>
                    val canvasTitle = activeCanvasMap?.get("title") as? String
                    android.util.Log.i("AmbientDisplay", "Discovered device: id=$id name=$name type=$type status=$status")
                    CloudDevice(id, name, type, status, lastSeen, canvasTitle)
                }
                onDevicesUpdated(devices)
            }
    }

    fun stopListening() {
        devicesListener?.remove()
        devicesListener = null
        stopListeningToPreferences()
    }

    /**
     * Send canvas payload to a list of target device IDs.
     * If targets contains "all", dispatches to all machine/macos devices.
     */
    suspend fun sendCanvasToDevices(
        targetDeviceIds: Collection<String>,
        canvasPayload: Map<String, Any>
    ): Boolean {
        val uid = auth.currentUser?.uid ?: return false
        val devicesColl = firestore.collection("users").document(uid).collection("devices")
        return try {
            if (targetDeviceIds.contains("all")) {
                val snapshot = devicesColl.get().await()
                for (doc in snapshot.documents) {
                    val dType = doc.getString("deviceType")
                    if (dType == "machine" || dType == "macos") {
                        doc.reference.update("activeCanvas", canvasPayload).await()
                    }
                }
            } else {
                for (id in targetDeviceIds) {
                    devicesColl.document(id).update("activeCanvas", canvasPayload).await()
                }
            }
            true
        } catch (e: Exception) {
            android.util.Log.e("AmbientDisplay", "Failed to send canvas to devices: ${e.message}", e)
            false
        }
    }

    suspend fun clearCanvasOnDevices(targetDeviceIds: Collection<String>): Boolean {
        val uid = auth.currentUser?.uid ?: return false
        val devicesColl = firestore.collection("users").document(uid).collection("devices")
        return try {
            if (targetDeviceIds.contains("all")) {
                val snapshot = devicesColl.get().await()
                for (doc in snapshot.documents) {
                    val dType = doc.getString("deviceType")
                    if (dType == "machine" || dType == "macos") {
                        doc.reference.update("activeCanvas", null).await()
                    }
                }
            } else {
                for (id in targetDeviceIds) {
                    devicesColl.document(id).update("activeCanvas", null).await()
                }
            }
            true
        } catch (e: Exception) {
            android.util.Log.e("AmbientDisplay", "Failed to clear canvas on devices: ${e.message}", e)
            false
        }
    }
}
