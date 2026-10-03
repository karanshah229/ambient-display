package com.wakemeup.service

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.wakemeup.MainActivity
import com.wakemeup.detector.InactivityCompensator
import com.wakemeup.detector.MidnightGlanceFilter
import com.wakemeup.network.MacSyncClient
import com.wakemeup.receiver.AlarmTriggerReceiver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class SleepDetectionService : Service() {

    companion object {
        const val CHANNEL_ID = "wake_me_up_foreground_service"
        const val NOTIFICATION_ID = 3001

        const val ACTION_START_SERVICE = "com.wakemeup.ACTION_START_SERVICE"
        const val ACTION_STOP_SERVICE = "com.wakemeup.ACTION_STOP_SERVICE"
        const val ACTION_MANUAL_SLEEP = "com.wakemeup.ACTION_MANUAL_SLEEP"
        const val ACTION_STOP_SLEEP = "com.wakemeup.ACTION_STOP_SLEEP"

        var isServiceRunning = false
            private set

        fun getActiveBedtimeMs(context: Context): Long? {
            val prefs = context.getSharedPreferences("WakeMeUpState", Context.MODE_PRIVATE)
            val v = prefs.getLong("bedtime_ms", -1L)
            return if (v > 0) v else null
        }

        fun getActiveTargetWakeMs(context: Context): Long? {
            val prefs = context.getSharedPreferences("WakeMeUpState", Context.MODE_PRIVATE)
            val v = prefs.getLong("target_wake_ms", -1L)
            return if (v > 0) v else null
        }
    }

    private var currentBedtimeMs: Long?
        get() = getActiveBedtimeMs(this)
        set(value) {
            val prefs = getSharedPreferences("WakeMeUpState", Context.MODE_PRIVATE)
            if (value != null) prefs.edit().putLong("bedtime_ms", value).apply()
            else prefs.edit().remove("bedtime_ms").apply()
        }

    private var currentTargetWakeMs: Long?
        get() = getActiveTargetWakeMs(this)
        set(value) {
            val prefs = getSharedPreferences("WakeMeUpState", Context.MODE_PRIVATE)
            if (value != null) prefs.edit().putLong("target_wake_ms", value).apply()
            else prefs.edit().remove("target_wake_ms").apply()
        }

    private val serviceScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private lateinit var syncClient: MacSyncClient
    private lateinit var glanceFilter: MidnightGlanceFilter
    private var screenReceiver: BroadcastReceiver? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        syncClient = MacSyncClient(this)
        glanceFilter = MidnightGlanceFilter(this) { newBedtimeMs ->
            startSleepSession(newBedtimeMs, 450.0, "midnight_reset")
        }

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "WakeMeUp::ServiceWakeLock")

        createNotificationChannel()
        registerScreenReceiver()
        isServiceRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = createForegroundNotification("Monitoring phone lock/unlock...")
        startForeground(NOTIFICATION_ID, notification)

        when (intent?.action) {
            ACTION_STOP_SERVICE -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_MANUAL_SLEEP -> {
                val now = System.currentTimeMillis()
                startSleepSession(now, 450.0, "manual_app_trigger")
            }
            ACTION_STOP_SLEEP -> {
                stopSleepSession()
            }
            MidnightGlanceFilter.ACTION_KEEP_ALARM -> {
                glanceFilter.dismissPrompt()
            }
            MidnightGlanceFilter.ACTION_RESET_BEDTIME -> {
                glanceFilter.dismissPrompt()
                val now = System.currentTimeMillis()
                startSleepSession(now, 450.0, "midnight_prompt_reset")
            }
        }

        return START_STICKY
    }

    private fun registerScreenReceiver() {
        if (screenReceiver != null) return

        screenReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    Intent.ACTION_SCREEN_ON -> {
                        if (currentBedtimeMs != null) {
                            glanceFilter.onScreenTurnedOn()
                        }
                    }
                    Intent.ACTION_USER_PRESENT -> {
                        // User unlocked phone
                        if (currentBedtimeMs != null) {
                            glanceFilter.onScreenUnlocked()
                        }
                    }
                    Intent.ACTION_SCREEN_OFF -> {
                        // Screen locked or turned off
                        handleScreenOff()
                    }
                }
            }
        }

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_USER_PRESENT)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        }
        registerReceiver(screenReceiver, filter)
    }

    private fun handleScreenOff() {
        // If an active sleep session exists: check if this was a <5 min glance
        if (currentBedtimeMs != null) {
            val isBriefGlance = glanceFilter.onScreenLocked()
            if (isBriefGlance) {
                // Ignore: keeps original sleep schedule intact
                return
            }
        }

        // New sleep detection or verified session
        val screenOffTime = System.currentTimeMillis()
        val calc = InactivityCompensator.calculateBedtime(this, screenOffTime)

        startSleepSession(
            bedtimeMs = calc.bedtimeEpochMs,
            durationMinutes = 450.0,
            reason = calc.reason
        )
    }

    private fun startSleepSession(bedtimeMs: Long, durationMinutes: Double, reason: String) {
        val targetWakeMs = bedtimeMs + (durationMinutes * 60 * 1000).toLong()
        currentBedtimeMs = bedtimeMs
        currentTargetWakeMs = targetWakeMs

        val timeFormat = SimpleDateFormat("h:mm a", Locale.getDefault())
        val targetString = timeFormat.format(Date(targetWakeMs))

        updateNotification("Sleeping: Target wake up at $targetString")

        // 1. Schedule exact hardware RTC alarm on Android phone
        scheduleExactPhoneAlarm(targetWakeMs)

        // 2. Transmit sleep event to Mac over Wi-Fi
        serviceScope.launch {
            wakeLock?.acquire(10_000L) // Hold CPU awake for up to 10s for network ping
            try {
                syncClient.sendSleepEvent(bedtimeMs, durationMinutes, reason)
            } finally {
                if (wakeLock?.isHeld == true) {
                    wakeLock?.release()
                }
            }
        }
    }

    private fun stopSleepSession() {
        currentBedtimeMs = null
        currentTargetWakeMs = null
        cancelExactPhoneAlarm()
        updateNotification("Monitoring phone lock/unlock...")

        serviceScope.launch {
            syncClient.sendWakeEvent()
        }
    }

    private fun scheduleExactPhoneAlarm(targetEpochMs: Long) {
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(this, AlarmTriggerReceiver::class.java)
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            100,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                targetEpochMs,
                pendingIntent
            )
        } else {
            alarmManager.setExact(
                AlarmManager.RTC_WAKEUP,
                targetEpochMs,
                pendingIntent
            )
        }
    }

    private fun cancelExactPhoneAlarm() {
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(this, AlarmTriggerReceiver::class.java)
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            100,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        alarmManager.cancel(pendingIntent)
    }

    private fun createForegroundNotification(statusText: String): Notification {
        val openIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("Wake Me Up")
            .setContentText(statusText)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build()
    }

    private fun updateNotification(statusText: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, createForegroundNotification(statusText))
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Wake Me Up Background Monitor",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps sleep detection alive reliably"
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        isServiceRunning = false
        screenReceiver?.let {
            unregisterReceiver(it)
            screenReceiver = null
        }
        serviceScope.cancel()
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
