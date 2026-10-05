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

    fun isHourInWindow(hour: Int, startHour: Int, endHour: Int): Boolean {
        return if (startHour <= endHour) {
            hour in startHour until endHour
        } else {
            hour >= startHour || hour < endHour
        }
    }

    fun onScreenTurnedOn() {
        if (unlockTimestamp == null) {
            unlockTimestamp = System.currentTimeMillis()
        }

        val config = SleepDetectionService.getSleepConfig(context)
        val currentHour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
        val isAutoPushWindow = isHourInWindow(currentHour, config.autoPushWindowStartHour, config.autoPushWindowEndHour)

        promptRunnable?.let { handler.removeCallbacks(it) }

        if (isAutoPushWindow) {
            // In 9-11 PM auto-push window, automatically reset without bothering user
            // No notification needed; when screen locks again or after 2 mins, auto push
        } else {
            // Outside auto-push window: Prompt after 3 minutes of continued activity
            promptRunnable = Runnable {
                showAwakePromptNotification()
            }
            handler.postDelayed(promptRunnable!!, 3 * 60 * 1000L)
        }
    }

    fun onScreenUnlocked() {
        onScreenTurnedOn()
    }

    /**
     * Called when screen turns off.
     * Returns true if this was an ignorable brief glance, false if sleep should be pushed/reset.
     */
    fun onScreenLocked(): Boolean {
        promptRunnable?.let { handler.removeCallbacks(it) }
        promptRunnable = null

        val unlockTime = unlockTimestamp ?: return true
        val durationMs = System.currentTimeMillis() - unlockTime
        unlockTimestamp = null

        val config = SleepDetectionService.getSleepConfig(context)
        val currentHour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
        val isAutoPushWindow = isHourInWindow(currentHour, config.autoPushWindowStartHour, config.autoPushWindowEndHour)

        if (isAutoPushWindow) {
            // In 9-11 PM window: any interaction pushes back the sleep window automatically!
            return false
        }

        // Outside auto-push window: brief glance (< 3 min) preserves sleep schedule
        return durationMs < (3 * 60 * 1000L)
    }

    fun showAwakePromptNotification() {
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
