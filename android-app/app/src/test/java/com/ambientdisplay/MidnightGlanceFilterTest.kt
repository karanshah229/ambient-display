package com.ambientdisplay

import com.ambientdisplay.detector.MidnightGlanceFilter
import com.ambientdisplay.service.SleepDetectionService
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MidnightGlanceFilterTest {

    @Test
    fun testIsHourInWindowOvernightWindow() {
        // Typical sleep window: 9 PM (21) to 6 AM (6)
        val startHour = 21
        val endHour = 6

        // Inside nocturnal sleep window
        assertTrue(SleepDetectionService.isHourInWindow(21, startHour, endHour))
        assertTrue(SleepDetectionService.isHourInWindow(22, startHour, endHour))
        assertTrue(SleepDetectionService.isHourInWindow(23, startHour, endHour))
        assertTrue(SleepDetectionService.isHourInWindow(0, startHour, endHour))
        assertTrue(SleepDetectionService.isHourInWindow(1, startHour, endHour))
        assertTrue(SleepDetectionService.isHourInWindow(3, startHour, endHour))
        assertTrue(SleepDetectionService.isHourInWindow(5, startHour, endHour))

        // Outside sleep window (daytime / after sleep hours)
        assertFalse(SleepDetectionService.isHourInWindow(6, startHour, endHour))
        assertFalse(SleepDetectionService.isHourInWindow(7, startHour, endHour))
        assertFalse(SleepDetectionService.isHourInWindow(8, startHour, endHour)) // 8:07 AM bug scenario
        assertFalse(SleepDetectionService.isHourInWindow(12, startHour, endHour))
        assertFalse(SleepDetectionService.isHourInWindow(18, startHour, endHour))
        assertFalse(SleepDetectionService.isHourInWindow(20, startHour, endHour))
    }

    @Test
    fun testIsHourInWindowAutoPushWindow() {
        // Auto push window: 9 PM (21) to 11 PM (23)
        val startHour = 21
        val endHour = 23

        assertTrue(SleepDetectionService.isHourInWindow(21, startHour, endHour))
        assertTrue(SleepDetectionService.isHourInWindow(22, startHour, endHour))

        assertFalse(SleepDetectionService.isHourInWindow(23, startHour, endHour))
        assertFalse(SleepDetectionService.isHourInWindow(0, startHour, endHour))
        assertFalse(SleepDetectionService.isHourInWindow(8, startHour, endHour))
    }

    @Test
    fun testIsHourInWindowDayWindow() {
        // Same-day window: 9 AM (9) to 5 PM (17)
        val startHour = 9
        val endHour = 17

        assertTrue(SleepDetectionService.isHourInWindow(9, startHour, endHour))
        assertTrue(SleepDetectionService.isHourInWindow(12, startHour, endHour))
        assertTrue(SleepDetectionService.isHourInWindow(16, startHour, endHour))

        assertFalse(SleepDetectionService.isHourInWindow(8, startHour, endHour))
        assertFalse(SleepDetectionService.isHourInWindow(17, startHour, endHour))
        assertFalse(SleepDetectionService.isHourInWindow(22, startHour, endHour))
    }

    @Test
    fun testBoundaryConditionsWindowTransition() {
        // Window 21 to 6
        // Exactly at start hour (21:00) -> inside window
        assertTrue(SleepDetectionService.isHourInWindow(21, 21, 6))
        // Exactly at end hour (06:00) -> outside window
        assertFalse(SleepDetectionService.isHourInWindow(6, 21, 6))
        // Mid-morning (10:00) -> outside window
        assertFalse(SleepDetectionService.isHourInWindow(10, 21, 6))
    }
}
