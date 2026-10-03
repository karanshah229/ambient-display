package com.wakemeup.detector

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.provider.Settings

data class SleepCalculationResult(
    val bedtimeEpochMs: Long,
    val deductedMinutes: Long,
    val systemTimeoutMinutes: Long,
    val reason: String
)

object InactivityCompensator {

    /**
     * Dynamically reads the current Android system screen off timeout in milliseconds.
     * Defaults to 30 minutes (1,800,000 ms) if unreadable.
     */
    fun getSystemScreenTimeoutMs(context: Context): Long {
        return try {
            Settings.System.getInt(
                context.contentResolver,
                Settings.System.SCREEN_OFF_TIMEOUT
            ).toLong()
        } catch (_: Exception) {
            1_800_000L // 30 minutes default
        }
    }

    /**
     * Calculates the estimated sleep time by inspecting live system screen timeout
     * and actual user interaction events from UsageStatsManager.
     */
    fun calculateBedtime(
        context: Context,
        screenOffTimeMs: Long = System.currentTimeMillis()
    ): SleepCalculationResult {
        val timeoutMs = getSystemScreenTimeoutMs(context)
        val timeoutMinutes = timeoutMs / 60_000L

        val lastInteractionMs = findLastUserInteractionTime(context, screenOffTimeMs, lookbackWindowMs = timeoutMs * 2)

        if (lastInteractionMs == null) {
            // No usage stats permission or events found: default to screenOff time
            return SleepCalculationResult(
                bedtimeEpochMs = screenOffTimeMs,
                deductedMinutes = 0,
                systemTimeoutMinutes = timeoutMinutes,
                reason = "active_manual_lock"
            )
        }

        val idleDurationMs = screenOffTimeMs - lastInteractionMs
        // If the gap between last touch and screen off is close to the system display timeout (within 60s tolerance),
        // it means the device sat idle (e.g. Netflix video ended or reading stopped) and locked automatically.
        val toleranceMs = 60_000L // 1 minute tolerance
        val isIdleTimeout = idleDurationMs >= (timeoutMs - toleranceMs)

        return if (isIdleTimeout) {
            // Deduct the idle timeout: estimated sleep began when interaction stopped
            val actualBedtime = maxOf(lastInteractionMs, screenOffTimeMs - timeoutMs)
            val deductedMins = (screenOffTimeMs - actualBedtime) / 60_000L
            SleepCalculationResult(
                bedtimeEpochMs = actualBedtime,
                deductedMinutes = deductedMins,
                systemTimeoutMinutes = timeoutMinutes,
                reason = "inactivity_timeout_compensated"
            )
        } else {
            // User was actively using phone right before screen turned off (e.g. manual lock)
            SleepCalculationResult(
                bedtimeEpochMs = screenOffTimeMs,
                deductedMinutes = 0,
                systemTimeoutMinutes = timeoutMinutes,
                reason = "active_lock"
            )
        }
    }

    private fun findLastUserInteractionTime(
        context: Context,
        referenceTimeMs: Long,
        lookbackWindowMs: Long
    ): Long? {
        val usageStatsManager = context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
            ?: return null

        val startTime = referenceTimeMs - lookbackWindowMs
        val events = try {
            usageStatsManager.queryEvents(startTime, referenceTimeMs)
        } catch (_: SecurityException) {
            return null
        }

        var latestEventTime: Long? = null
        val event = UsageEvents.Event()

        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            // USER_INTERACTION (added in API 28) or ACTIVITY_RESUMED / ACTIVITY_PAUSED
            if (event.eventType == UsageEvents.Event.USER_INTERACTION ||
                event.eventType == UsageEvents.Event.ACTIVITY_RESUMED ||
                event.eventType == UsageEvents.Event.ACTIVITY_PAUSED
            ) {
                if (latestEventTime == null || event.timeStamp > latestEventTime) {
                    latestEventTime = event.timeStamp
                }
            }
        }

        return latestEventTime
    }
}
