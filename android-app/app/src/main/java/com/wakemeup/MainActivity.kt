package com.wakemeup

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.wakemeup.detector.InactivityCompensator
import com.wakemeup.network.MacSyncClient
import com.wakemeup.service.SleepDetectionService
import com.wakemeup.util.OxygenOSHelper
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : AppCompatActivity() {

    private lateinit var syncClient: MacSyncClient
    private lateinit var tvSleepStatus: TextView
    private lateinit var tvWakeTarget: TextView
    private lateinit var tvDisplayTimeout: TextView
    private lateinit var etMacHost: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        syncClient = MacSyncClient(this)

        initViews()
        startSleepService()
        refreshStatus()
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
    }

    private fun initViews() {
        tvSleepStatus = findViewById(R.id.tvSleepStatus)
        tvWakeTarget = findViewById(R.id.tvWakeTarget)
        tvDisplayTimeout = findViewById(R.id.tvDisplayTimeout)
        etMacHost = findViewById(R.id.etMacHost)

        etMacHost.setText(syncClient.macHost)

        findViewById<Button>(R.id.btnSaveHost).setOnClickListener {
            val host = etMacHost.text.toString().trim()
            if (host.isNotEmpty()) {
                syncClient.macHost = host
                Toast.makeText(this, "Mac IP saved: $host", Toast.LENGTH_SHORT).show()
            }
        }

        findViewById<Button>(R.id.btnTestConnection).setOnClickListener {
            testMacConnection()
        }

        findViewById<Button>(R.id.btnManualSleep).setOnClickListener {
            val intent = Intent(this, SleepDetectionService::class.java).apply {
                action = SleepDetectionService.ACTION_MANUAL_SLEEP
            }
            startService(intent)
            Toast.makeText(this, "Manual 7.5h sleep started!", Toast.LENGTH_SHORT).show()
            refreshStatus()
        }

        findViewById<Button>(R.id.btnTestMode).setOnClickListener {
            lifecycleScope.launch {
                val res = syncClient.sendTestEvent(durationSeconds = 10)
                if (res.isSuccess) {
                    Toast.makeText(this@MainActivity, "Test preview triggered on Mac (10s)!", Toast.LENGTH_SHORT).show()
                } else {
                    Toast.makeText(this@MainActivity, "Error: ${res.exceptionOrNull()?.message}", Toast.LENGTH_LONG).show()
                }
            }
        }

        findViewById<Button>(R.id.btnStopSleep).setOnClickListener {
            val intent = Intent(this, SleepDetectionService::class.java).apply {
                action = SleepDetectionService.ACTION_STOP_SLEEP
            }
            startService(intent)
            Toast.makeText(this, "Sleep stopped", Toast.LENGTH_SHORT).show()
            refreshStatus()
        }

        // OnePlus Setup Checklist buttons
        findViewById<Button>(R.id.btnBatteryOpt).setOnClickListener {
            OxygenOSHelper.requestIgnoreBatteryOptimizations(this)
        }

        findViewById<Button>(R.id.btnUsageAccess).setOnClickListener {
            OxygenOSHelper.openUsageStatsSettings(this)
        }

        findViewById<Button>(R.id.btnAccessibility).setOnClickListener {
            OxygenOSHelper.openAccessibilitySettings(this)
        }

        findViewById<Button>(R.id.btnAutoLaunch).setOnClickListener {
            OxygenOSHelper.openOnePlusAutoLaunchSettings(this)
        }
    }

    private fun startSleepService() {
        val intent = Intent(this, SleepDetectionService::class.java).apply {
            action = SleepDetectionService.ACTION_START_SERVICE
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun refreshStatus() {
        val timeoutMs = InactivityCompensator.getSystemScreenTimeoutMs(this)
        val timeoutMinutes = timeoutMs / 60_000L
        tvDisplayTimeout.text = "Live Display Sleep Timeout: $timeoutMinutes minutes"

        val targetMs = SleepDetectionService.currentTargetWakeMs
        if (targetMs != null) {
            val timeFormat = SimpleDateFormat("h:mm a", Locale.getDefault())
            tvSleepStatus.text = "Status: Sleeping"
            tvWakeTarget.text = "Target Wake Up: ${timeFormat.format(Date(targetMs))} (7.5h)"
        } else {
            tvSleepStatus.text = "Status: Monitoring Lock Events"
            tvWakeTarget.text = "Target: Standby"
        }
    }

    private fun testMacConnection() {
        lifecycleScope.launch {
            Toast.makeText(this@MainActivity, "Testing connection to ${syncClient.macHost}...", Toast.LENGTH_SHORT).show()
            val result = syncClient.fetchStatus()
            if (result.isSuccess) {
                Toast.makeText(this@MainActivity, "Connected to Mac successfully!", Toast.LENGTH_SHORT).show()
            } else {
                Toast.makeText(this@MainActivity, "Failed: ${result.exceptionOrNull()?.message}", Toast.LENGTH_LONG).show()
            }
        }
    }
}
