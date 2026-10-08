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
    val lastSeen: Timestamp? = null
)

class DeviceSyncManager(private val context: Context) {
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance()
    private val auth: FirebaseAuth = FirebaseAuth.getInstance()
    private var devicesListener: ListenerRegistration? = null

    val deviceId: String by lazy {
        val androidId = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: "phone"
        "android_$androidId"
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
            "deviceType" to "android",
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
                    CloudDevice(id, name, type, status, lastSeen)
                }
                onDevicesUpdated(devices)
            }
    }

    fun stopListening() {
        devicesListener?.remove()
        devicesListener = null
    }

    suspend fun sendCanvasToDevice(
        targetDeviceId: String,
        canvasPayload: Map<String, Any>
    ): Boolean {
        val uid = auth.currentUser?.uid ?: return false
        val devicesColl = firestore.collection("users").document(uid).collection("devices")
        return try {
            if (targetDeviceId == "all") {
                val snapshot = devicesColl.whereEqualTo("deviceType", "macos").get().await()
                for (doc in snapshot.documents) {
                    doc.reference.update("activeCanvas", canvasPayload).await()
                }
            } else {
                devicesColl.document(targetDeviceId).update("activeCanvas", canvasPayload).await()
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    suspend fun clearCanvasOnDevice(targetDeviceId: String): Boolean {
        val uid = auth.currentUser?.uid ?: return false
        val devicesColl = firestore.collection("users").document(uid).collection("devices")
        return try {
            if (targetDeviceId == "all") {
                val snapshot = devicesColl.whereEqualTo("deviceType", "macos").get().await()
                for (doc in snapshot.documents) {
                    doc.reference.update("activeCanvas", null).await()
                }
            } else {
                devicesColl.document(targetDeviceId).update("activeCanvas", null).await()
            }
            true
        } catch (e: Exception) {
            false
        }
    }
}
