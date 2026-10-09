package com.ambientdisplay.service

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Build
import android.view.accessibility.AccessibilityEvent

/**
 * AccessibilityWatchdogService:
 * 1. Immune to OnePlus / OxygenOS / ColorOS background task killer.
 * 2. Ensures the SleepDetectionService is automatically restarted if ever killed.
 */
class AccessibilityWatchdogService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        ensureSleepServiceRunning()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Active user interaction occurred
        ensureSleepServiceRunning()
    }

    override fun onInterrupt() {}

    private fun ensureSleepServiceRunning() {
        if (!SleepDetectionService.isServiceRunning) {
            val intent = Intent(this, SleepDetectionService::class.java).apply {
                action = SleepDetectionService.ACTION_START_SERVICE
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        }
    }
}
