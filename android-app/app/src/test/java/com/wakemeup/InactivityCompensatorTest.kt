package com.wakemeup

import com.wakemeup.detector.MidnightGlanceFilter
import com.wakemeup.detector.SleepCalculationResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InactivityCompensatorTest {

    @Test
    fun testSleepCalculationResultWithTimeoutCompensation() {
        val screenOffTime = 1700000000000L
        val timeoutMs = 30 * 60 * 1000L // 30 minutes = 1,800,000 ms
        val actualBedtime = screenOffTime - timeoutMs

        val result = SleepCalculationResult(
            bedtimeEpochMs = actualBedtime,
            deductedMinutes = 30,
            systemTimeoutMinutes = 30,
            reason = "inactivity_timeout_compensated"
        )

        assertEquals(actualBedtime, result.bedtimeEpochMs)
        assertEquals(30L, result.deductedMinutes)
        assertEquals(30L, result.systemTimeoutMinutes)
        assertEquals("inactivity_timeout_compensated", result.reason)
    }

    @Test
    fun testSleepCalculationResultActiveLock() {
        val screenOffTime = 1700000000000L

        val result = SleepCalculationResult(
            bedtimeEpochMs = screenOffTime,
            deductedMinutes = 0,
            systemTimeoutMinutes = 30,
            reason = "active_lock"
        )

        assertEquals(screenOffTime, result.bedtimeEpochMs)
        assertEquals(0L, result.deductedMinutes)
        assertEquals("active_lock", result.reason)
    }

    @Test
    fun testMidnightGlanceThresholdConstant() {
        // Must be exactly 5 minutes (300,000 ms)
        assertEquals(300_000L, MidnightGlanceFilter.MIDNIGHT_THRESHOLD_MS)

        val quickGlanceDuration = 2 * 60 * 1000L // 2 minutes
        assertTrue(quickGlanceDuration < MidnightGlanceFilter.MIDNIGHT_THRESHOLD_MS)

        val prolongedWakeDuration = 6 * 60 * 1000L // 6 minutes
        assertFalse(prolongedWakeDuration < MidnightGlanceFilter.MIDNIGHT_THRESHOLD_MS)
    }
}
