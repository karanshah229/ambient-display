package com.ambientdisplay.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import com.ambientdisplay.service.SleepDetectionService

class SleepWindowReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "SleepWindowReceiver"
        const val ACTION_WINDOW_TRANSITION = "com.ambientdisplay.ACTION_WINDOW_TRANSITION"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.i(TAG, "SleepWindowReceiver received action=${intent.action}")

        val shouldRun = SleepDetectionService.shouldRunService(context)
        Log.i(TAG, "shouldRunService evaluation: $shouldRun")

        if (shouldRun) {
            val serviceIntent = Intent(context, SleepDetectionService::class.java).apply {
                action = SleepDetectionService.ACTION_START_SERVICE
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start SleepDetectionService: ${e.message}", e)
            }
        } else {
            if (SleepDetectionService.isServiceRunning) {
                val updateIntent = Intent(context, SleepDetectionService::class.java).apply {
                    action = SleepDetectionService.ACTION_UPDATE_STATUS
                }
                try {
                    context.startService(updateIntent)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to update SleepDetectionService: ${e.message}", e)
                }
            }
            SleepDetectionService.scheduleNextWindowTransitionAlarm(context)
        }
    }
}
