package com.wakemeup.detector

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import com.wakemeup.service.SleepDetectionService

class MidnightGlanceFilter(
    private val context: Context,
    private val onResetConfirmed: (Long) -> Unit
) {
    companion object {
        const val MIDNIGHT_THRESHOLD_MS = 5 * 60 * 1000L // 5 minutes
        const val CHANNEL_ID = "wake_me_up_prompts"
        const val NOTIFICATION_ID = 4001

        const val ACTION_KEEP_ALARM = "com.wakemeup.ACTION_KEEP_ALARM"
        const val ACTION_RESET_BEDTIME = "com.wakemeup.ACTION_RESET_BEDTIME"
    }

    private var unlockTimestamp: Long? = null
    private val handler = Handler(Looper.getMainLooper())
    private var promptRunnable: Runnable? = null

    init {
        createNotificationChannel()
    }

    fun onScreenUnlocked() {
        unlockTimestamp = System.currentTimeMillis()

        // Schedule prompt if user stays awake for > 5 minutes
        promptRunnable?.let { handler.removeCallbacks(it) }
        promptRunnable = Runnable {
            showAwakePromptNotification()
        }
        handler.postDelayed(promptRunnable!!, MIDNIGHT_THRESHOLD_MS)
    }

    /**
     * Called when screen turns off.
     * Returns true if this was an ignorable brief glance (< 5 min), false otherwise.
     */
    fun onScreenLocked(): Boolean {
        promptRunnable?.let { handler.removeCallbacks(it) }
        promptRunnable = null

        val unlockTime = unlockTimestamp ?: return false
        val durationMs = System.currentTimeMillis() - unlockTime
        unlockTimestamp = null

        return if (durationMs < MIDNIGHT_THRESHOLD_MS) {
            // Ignored brief glance - do not alter sleep session
            true
        } else {
            // User was awake longer than threshold
            false
        }
    }

    private fun showAwakePromptNotification() {
        val keepIntent = Intent(context, SleepDetectionService::class.java).apply {
            action = ACTION_KEEP_ALARM
        }
        val keepPendingIntent = PendingIntent.getService(
            context,
            1,
            keepIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val resetIntent = Intent(context, SleepDetectionService::class.java).apply {
            action = ACTION_RESET_BEDTIME
        }
        val resetPendingIntent = PendingIntent.getService(
            context,
            2,
            resetIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("Still sleeping?")
            .setContentText("You've been active for 5+ minutes. Reset sleep target to 7.5 hours from now?")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Keep Alarm", keepPendingIntent)
            .addAction(android.R.drawable.ic_menu_rotate, "Reset Bedtime to Now", resetPendingIntent)
            .build()

        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(NOTIFICATION_ID, notification)
    }

    fun dismissPrompt() {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(NOTIFICATION_ID)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Sleep State Prompts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Asks if you woke up when active at night"
            }
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }
}
