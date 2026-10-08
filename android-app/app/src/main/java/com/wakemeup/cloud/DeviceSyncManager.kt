package com.wakemeup.cloud

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
        docRef.set(data)
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
