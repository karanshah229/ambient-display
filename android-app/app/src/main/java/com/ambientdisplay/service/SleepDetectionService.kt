package com.ambientdisplay.service

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
import android.content.SharedPreferences
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.ambientdisplay.MainActivity
import com.ambientdisplay.detector.InactivityCompensator
import com.ambientdisplay.detector.MidnightGlanceFilter
import com.ambientdisplay.network.MacSyncClient
import com.ambientdisplay.receiver.AlarmTriggerReceiver
import com.ambientdisplay.receiver.SleepWindowReceiver
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
        const val CHANNEL_ID = "ambient_display_foreground_service"
        const val NOTIFICATION_ID = 3001

        const val ACTION_START_SERVICE = "com.ambientdisplay.ACTION_START_SERVICE"
        const val ACTION_STOP_SERVICE = "com.ambientdisplay.ACTION_STOP_SERVICE"
        const val ACTION_MANUAL_SLEEP = "com.ambientdisplay.ACTION_MANUAL_SLEEP"
        const val ACTION_STOP_SLEEP = "com.ambientdisplay.ACTION_STOP_SLEEP"
        const val ACTION_UPDATE_STATUS = "com.ambientdisplay.ACTION_UPDATE_STATUS"
        const val ACTION_SHOW_MIDNIGHT_PROMPT = "com.ambientdisplay.ACTION_SHOW_MIDNIGHT_PROMPT"
        const val EXTRA_DURATION_MINUTES = "com.ambientdisplay.EXTRA_DURATION_MINUTES"

        var isServiceRunning = false
            private set

        fun getPrefs(context: Context): SharedPreferences {
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
            return newPrefs
        }

        fun getStatePrefs(context: Context): SharedPreferences {
            val newState = context.getSharedPreferences("AmbientDisplayState", Context.MODE_PRIVATE)
            val oldState = context.getSharedPreferences("AmbientDisplayState", Context.MODE_PRIVATE)
            if (oldState.all.isNotEmpty() && newState.all.isEmpty()) {
                val editor = newState.edit()
                for ((k, v) in oldState.all) {
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
            return newState
        }

        fun isHourInWindow(hour: Int, startHour: Int, endHour: Int): Boolean {
            return if (startHour <= endHour) {
                hour in startHour until endHour
            } else {
                hour >= startHour || hour < endHour
            }
        }

        fun formatHour(hour: Int): String {
            val h = if (hour % 12 == 0) 12 else hour % 12
            val ampm = if (hour < 12) "AM" else "PM"
            return "$h:00 $ampm"
        }

        fun getActiveBedtimeMs(context: Context): Long? {
            val prefs = getStatePrefs(context)
            val v = prefs.getLong("bedtime_ms", -1L)
            return if (v > 0) v else null
        }

        fun getActiveTargetWakeMs(context: Context): Long? {
            val prefs = getStatePrefs(context)
            val v = prefs.getLong("target_wake_ms", -1L)
            return if (v > 0) v else null
        }

        fun getSleepConfig(context: Context): MacSyncClient.AppConfig {
            val prefs = getPrefs(context)
            return MacSyncClient.AppConfig(
                defaultSleepHours = prefs.getFloat("default_sleep_hours", 7.5f).toDouble(),
                sleepWindowStartHour = prefs.getInt("sleep_window_start_hour", 21),
                sleepWindowEndHour = prefs.getInt("sleep_window_end_hour", 6),
                autoPushWindowStartHour = prefs.getInt("auto_push_window_start_hour", 21),
                autoPushWindowEndHour = prefs.getInt("auto_push_window_end_hour", 23),
                inactivityOffsetMinutes = prefs.getFloat("inactivity_offset_minutes", 30.0f).toDouble(),
                autoDetectInactivity = prefs.getBoolean("auto_detect_inactivity", true),
                isAwayMode = prefs.getBoolean("is_away_mode", false),
                ambientNightColorHex = prefs.getString("ambient_night_color_hex", "#D95926") ?: "#D95926",
                ambientDawnColorHex = prefs.getString("ambient_dawn_color_hex", "#FA7268") ?: "#FA7268",
                ambientWakeColorHex = prefs.getString("ambient_wake_color_hex", "#FFD000") ?: "#FFD000"
            )
        }

        fun shouldRunService(context: Context): Boolean {
            val bedtime = getActiveBedtimeMs(context)
            val targetWake = getActiveTargetWakeMs(context)
            val now = System.currentTimeMillis()

            // 1. If an active sleep session exists and hasn't passed its wake target: must run
            if (bedtime != null && targetWake != null && now < targetWake) {
                return true
            }

            // 2. If Away Mode is enabled: never run in background
            val config = getSleepConfig(context)
            if (config.isAwayMode) {
                return false
            }

            // 3. Must be within the eligible sleep window (e.g. 9:00 PM – 6:00 AM)
            val currentHour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
            return isHourInWindow(currentHour, config.sleepWindowStartHour, config.sleepWindowEndHour)
        }

        fun scheduleNextWindowTransitionAlarm(context: Context) {
            val config = getSleepConfig(context)
            val now = System.currentTimeMillis()

            fun getNextOccurrence(hour: Int): Long {
                val cal = java.util.Calendar.getInstance().apply {
                    timeInMillis = now
                    set(java.util.Calendar.HOUR_OF_DAY, hour)
                    set(java.util.Calendar.MINUTE, 0)
                    set(java.util.Calendar.SECOND, 0)
                    set(java.util.Calendar.MILLISECOND, 0)
                }
                if (cal.timeInMillis <= now) {
                    cal.add(java.util.Calendar.DAY_OF_YEAR, 1)
                }
                return cal.timeInMillis
            }

            val nextStart = getNextOccurrence(config.sleepWindowStartHour)
            val nextEnd = getNextOccurrence(config.sleepWindowEndHour)
            val nextTrigger = minOf(nextStart, nextEnd)

            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, SleepWindowReceiver::class.java).apply {
                action = SleepWindowReceiver.ACTION_WINDOW_TRANSITION
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                200,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, nextTrigger, pendingIntent)
            } else {
                alarmManager.setExact(AlarmManager.RTC_WAKEUP, nextTrigger, pendingIntent)
            }
        }

        fun cancelNextWindowTransitionAlarm(context: Context) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, SleepWindowReceiver::class.java).apply {
                action = SleepWindowReceiver.ACTION_WINDOW_TRANSITION
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                200,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            alarmManager.cancel(pendingIntent)
        }

        fun saveSleepConfig(context: Context, config: MacSyncClient.AppConfig) {
            val prefs = getPrefs(context)
            prefs.edit()
                .putFloat("default_sleep_hours", config.defaultSleepHours.toFloat())
                .putInt("sleep_window_start_hour", config.sleepWindowStartHour)
                .putInt("sleep_window_end_hour", config.sleepWindowEndHour)
                .putInt("auto_push_window_start_hour", config.autoPushWindowStartHour)
                .putInt("auto_push_window_end_hour", config.autoPushWindowEndHour)
                .putFloat("inactivity_offset_minutes", config.inactivityOffsetMinutes.toFloat())
                .putBoolean("auto_detect_inactivity", config.autoDetectInactivity)
                .putBoolean("is_away_mode", config.isAwayMode)
                .putString("ambient_night_color_hex", config.ambientNightColorHex)
                .putString("ambient_dawn_color_hex", config.ambientDawnColorHex)
                .putString("ambient_wake_color_hex", config.ambientWakeColorHex)
                .apply()

            if (shouldRunService(context)) {
                val intent = Intent(context, SleepDetectionService::class.java).apply {
                    action = ACTION_START_SERVICE
                }
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            } else {
                if (isServiceRunning) {
                    val intent = Intent(context, SleepDetectionService::class.java).apply {
                        action = ACTION_UPDATE_STATUS
                    }
                    try {
                        context.startService(intent)
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }
                }
                scheduleNextWindowTransitionAlarm(context)
            }
        }
    }

    private var currentBedtimeMs: Long?
        get() = getActiveBedtimeMs(this)
        set(value) {
            val prefs = getStatePrefs(this)
            if (value != null) prefs.edit().putLong("bedtime_ms", value).apply()
            else prefs.edit().remove("bedtime_ms").apply()
        }

    private var currentTargetWakeMs: Long?
        get() = getActiveTargetWakeMs(this)
        set(value) {
            val prefs = getStatePrefs(this)
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
            val config = getSleepConfig(this)
            startSleepSession(newBedtimeMs, config.defaultSleepHours * 60.0, "midnight_reset")
        }

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AmbientDisplay::ServiceWakeLock")

        createNotificationChannel()
        registerScreenReceiver()
        isServiceRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val config = getSleepConfig(this)

        when (intent?.action) {
            ACTION_STOP_SERVICE -> {
                stopForegroundAndSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE_STATUS -> {
                if (!shouldRunService(this)) {
                    stopForegroundAndSelf()
                    return START_NOT_STICKY
                }
                updateStandbyNotification()
                return START_STICKY
            }
            ACTION_MANUAL_SLEEP -> {
                val now = System.currentTimeMillis()
                val overrideMinutes = intent.getDoubleExtra(EXTRA_DURATION_MINUTES, -1.0)
                val durationMinutes = if (overrideMinutes > 0) overrideMinutes else config.defaultSleepHours * 60.0
                startSleepSession(now, durationMinutes, "manual_app_trigger")
            }
            ACTION_STOP_SLEEP -> {
                stopSleepSession()
                if (!shouldRunService(this)) {
                    stopForegroundAndSelf()
                    return START_NOT_STICKY
                }
                return START_STICKY
            }
            ACTION_SHOW_MIDNIGHT_PROMPT -> {
                val currentHour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
                val isEligible = isHourInWindow(currentHour, config.sleepWindowStartHour, config.sleepWindowEndHour)
                if (!config.isAwayMode && isEligible) {
                    glanceFilter.showAwakePromptNotification()
                }
            }
            MidnightGlanceFilter.ACTION_KEEP_ALARM -> {
                glanceFilter.dismissPrompt()
            }
            MidnightGlanceFilter.ACTION_RESET_BEDTIME -> {
                glanceFilter.dismissPrompt()
                if (!config.isAwayMode) {
                    val now = System.currentTimeMillis()
                    startSleepSession(now, config.defaultSleepHours * 60.0, "midnight_prompt_reset")
                }
            }
        }

        if (!shouldRunService(this)) {
            scheduleNextWindowTransitionAlarm(this)
            stopForegroundAndSelf()
            return START_NOT_STICKY
        }

        val notification = createForegroundNotification(getStandbyStatusText())
        startForeground(NOTIFICATION_ID, notification)
        scheduleNextWindowTransitionAlarm(this)

        return START_STICKY
    }

    private fun stopForegroundAndSelf() {
        glanceFilter.dismissPrompt()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(NOTIFICATION_ID)
        stopSelf()
    }

    private fun getStandbyStatusText(): String {
        val config = getSleepConfig(this)
        if (config.isAwayMode) {
            return "Away Mode · Sleep detection paused"
        }

        val targetMs = currentTargetWakeMs
        val now = System.currentTimeMillis()
        if (currentBedtimeMs != null && targetMs != null && now < targetMs) {
            val timeFormat = SimpleDateFormat("h:mm a", Locale.getDefault())
            return "Sleeping: Target wake up at ${timeFormat.format(Date(targetMs))}"
        }

        val calendar = java.util.Calendar.getInstance()
        val currentHour = calendar.get(java.util.Calendar.HOUR_OF_DAY)
        val isEligible = isHourInWindow(currentHour, config.sleepWindowStartHour, config.sleepWindowEndHour)

        return if (isEligible) {
            "Monitoring phone lock/unlock (${formatHour(config.sleepWindowStartHour)} – ${formatHour(config.sleepWindowEndHour)})"
        } else {
            "Standby · Sleep window: ${formatHour(config.sleepWindowStartHour)} – ${formatHour(config.sleepWindowEndHour)}"
        }
    }

    private fun updateStandbyNotification() {
        updateNotification(getStandbyStatusText())
    }

    private fun registerScreenReceiver() {
        if (screenReceiver != null) return

        screenReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val now = System.currentTimeMillis()
                val targetMs = currentTargetWakeMs
                val config = getSleepConfig(this@SleepDetectionService)
                val currentHour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
                val isEligible = isHourInWindow(currentHour, config.sleepWindowStartHour, config.sleepWindowEndHour)

                // If wake target already passed or current time is outside the sleep window,
                // any lingering night sleep session is finished and should be stopped.
                if (currentBedtimeMs != null && (targetMs != null && now >= targetMs || !isEligible)) {
                    stopSleepSession()
                }

                if (!shouldRunService(this@SleepDetectionService)) {
                    scheduleNextWindowTransitionAlarm(this@SleepDetectionService)
                    stopForegroundAndSelf()
                    return
                }

                when (intent.action) {
                    Intent.ACTION_SCREEN_ON -> {
                        if (currentBedtimeMs != null && isEligible) {
                            glanceFilter.onScreenTurnedOn()
                        } else {
                            updateStandbyNotification()
                        }
                    }
                    Intent.ACTION_USER_PRESENT -> {
                        // User unlocked phone
                        if (currentBedtimeMs != null && isEligible) {
                            glanceFilter.onScreenUnlocked()
                        } else {
                            updateStandbyNotification()
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
        val now = System.currentTimeMillis()
        val targetMs = currentTargetWakeMs
        val config = getSleepConfig(this)
        val calendar = java.util.Calendar.getInstance()
        val currentHour = calendar.get(java.util.Calendar.HOUR_OF_DAY)
        val isEligible = isHourInWindow(currentHour, config.sleepWindowStartHour, config.sleepWindowEndHour)

        // If active session exists but wake target already passed or outside sleep window, end session
        if (currentBedtimeMs != null && (targetMs != null && now >= targetMs || !isEligible)) {
            stopSleepSession()
            if (!shouldRunService(this)) {
                scheduleNextWindowTransitionAlarm(this)
                stopForegroundAndSelf()
                return
            }
        }

        if (!shouldRunService(this)) {
            scheduleNextWindowTransitionAlarm(this)
            stopForegroundAndSelf()
            return
        }

        // 1. If an active sleep session exists within sleep window: check if this was an ignorable glance or push target
        if (currentBedtimeMs != null && isEligible) {
            val isBriefGlance = glanceFilter.onScreenLocked()
            if (isBriefGlance) {
                // Ignore: keeps original sleep schedule intact
                return
            }
            // User had prolonged activity or was in auto-push window:
            // Recalculate and push sleep target forward
            val reason = if (isHourInWindow(currentHour, config.autoPushWindowStartHour, config.autoPushWindowEndHour)) {
                "auto_push_window_update"
            } else {
                "night_active_pushed"
            }
            startSleepSession(
                bedtimeMs = now,
                durationMinutes = config.defaultSleepHours * 60.0,
                reason = reason
            )
            return
        }

        // 2. Check Eligible Sleep Window (default: 9 PM – 6 AM)
        if (!isEligible) {
            // Outside eligible sleep window (e.g. 3:00 PM on a workday):
            // Phone inactivity is ignored! Do NOT trigger sleep.
            updateStandbyNotification()
            return
        }

        // 3. Inactivity compensation & Sleep trigger within window
        val calc = InactivityCompensator.calculateBedtime(this, now)

        startSleepSession(
            bedtimeMs = calc.bedtimeEpochMs,
            durationMinutes = config.defaultSleepHours * 60.0,
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
        glanceFilter.dismissPrompt()
        currentBedtimeMs = null
        currentTargetWakeMs = null
        cancelExactPhoneAlarm()
        
        // Stop any actively ringing alarm
        val dismissIntent = Intent(this, AlarmTriggerReceiver::class.java).apply {
            action = AlarmTriggerReceiver.ACTION_DISMISS_ALARM
        }
        sendBroadcast(dismissIntent)

        if (!shouldRunService(this)) {
            scheduleNextWindowTransitionAlarm(this)
            stopForegroundAndSelf()
        } else {
            updateStandbyNotification()
            scheduleNextWindowTransitionAlarm(this)
        }

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
            .setContentTitle("Ambient Display")
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
                "Ambient Display Monitor",
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
