package com.wakemeup

import android.content.Context
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

import android.view.View
import android.widget.ArrayAdapter
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.Spinner
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import android.Manifest
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.text.Editable
import android.text.TextWatcher
import com.google.android.material.chip.Chip
import com.google.android.material.chip.ChipGroup
import org.json.JSONArray

class MainActivity : AppCompatActivity() {

    private lateinit var syncClient: MacSyncClient
    private lateinit var tvSleepStatus: TextView
    private lateinit var tvWakeTarget: TextView
    private lateinit var tvDisplayTimeout: TextView
    private lateinit var tvSleepDuration: TextView
    private lateinit var tvSleepWindow: TextView
    private lateinit var tvAutoPushWindow: TextView
    private lateinit var switchAwayMode: com.google.android.material.materialswitch.MaterialSwitch
    private lateinit var etMacHost: EditText
    private var isUpdatingAwaySwitch = false

    private lateinit var etScreenMessage: EditText
    private lateinit var etCanvasSubtitle: EditText
    private lateinit var spTargetDisplay: Spinner
    private lateinit var rgMessageDuration: RadioGroup
    private lateinit var rbPersistent: RadioButton
    private lateinit var rbLockPhoneOnly: RadioButton
    private lateinit var rbToast15s: RadioButton
    private lateinit var rbToast30s: RadioButton
    private lateinit var btnSendMessage: Button
    private lateinit var btnDismissScreenMessage: Button
    private lateinit var tvActiveMessageStatus: TextView
    private lateinit var chipGroupRecentMessages: ChipGroup
    private var connectedDisplays: List<MacSyncClient.DisplayInfo> = emptyList()

    private val PREFS_KEY_LAST_MESSAGE = "last_screen_message"
    private val PREFS_KEY_MESSAGE_HISTORY = "screen_message_history"
    private val defaultMessages = listOf(
        "At the Gym",
        "Taking a quick walk. Back in 15m!",
        "BRB in 10m",
        "Focus Time / In a Call",
        "Do Not Touch / Rendering"
    )

    private val requestNotificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { isGranted ->
            if (isGranted) {
                startSleepService()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        syncClient = MacSyncClient(this)

        initViews()
        checkNotificationPermission()
        refreshStatus()
        syncConfigFromMac()
        loadDisplays()
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.getBooleanExtra("trigger_midnight_prompt", false) == true) {
            val serviceIntent = Intent(this, SleepDetectionService::class.java).apply {
                action = SleepDetectionService.ACTION_SHOW_MIDNIGHT_PROMPT
            }
            startService(serviceIntent)
        }
    }

    private fun checkNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
                requestNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                return
            }
        }
        startSleepService()
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
        syncConfigFromMac()
        loadDisplays()
    }

    private fun initViews() {
        tvSleepStatus = findViewById(R.id.tvSleepStatus)
        tvWakeTarget = findViewById(R.id.tvWakeTarget)
        tvDisplayTimeout = findViewById(R.id.tvDisplayTimeout)
        tvSleepDuration = findViewById(R.id.tvSleepDuration)
        tvSleepWindow = findViewById(R.id.tvSleepWindow)
        tvAutoPushWindow = findViewById(R.id.tvAutoPushWindow)
        switchAwayMode = findViewById(R.id.switchAwayMode)
        etMacHost = findViewById(R.id.etMacHost)

        etMacHost.setText(syncClient.macHost)

        switchAwayMode.setOnCheckedChangeListener { _, isChecked ->
            if (isUpdatingAwaySwitch) return@setOnCheckedChangeListener
            val config = SleepDetectionService.getSleepConfig(this)
            val updated = config.copy(isAwayMode = isChecked)
            SleepDetectionService.saveSleepConfig(this, updated)

            lifecycleScope.launch {
                val res = syncClient.sendAwayEvent(isChecked)
                if (res.isSuccess) {
                    Toast.makeText(this@MainActivity, if (isChecked) "Away Mode Enabled on Mac" else "Away Mode Disabled on Mac", Toast.LENGTH_SHORT).show()
                } else {
                    Toast.makeText(this@MainActivity, "Failed to sync Away Mode to Mac: ${res.exceptionOrNull()?.message}", Toast.LENGTH_SHORT).show()
                }
            }
        }

        findViewById<Button>(R.id.btnSyncConfig).setOnClickListener {
            syncConfigFromMac()
        }

        findViewById<Button>(R.id.btnSaveHost).setOnClickListener {
            val host = etMacHost.text.toString().trim()
            if (host.isNotEmpty()) {
                syncClient.macHost = host
                Toast.makeText(this, "Mac IP saved: $host", Toast.LENGTH_SHORT).show()
                syncConfigFromMac()
            }
        }

        findViewById<Button>(R.id.btnTestConnection).setOnClickListener {
            testMacConnection()
        }

        findViewById<Button>(R.id.btnAutoDiscover).setOnClickListener {
            discoverMac()
        }

        findViewById<Button>(R.id.btnManualSleep).setOnClickListener {
            val config = SleepDetectionService.getSleepConfig(this)
            val intent = Intent(this, SleepDetectionService::class.java).apply {
                action = SleepDetectionService.ACTION_MANUAL_SLEEP
            }
            startService(intent)
            Toast.makeText(this, "Manual ${config.defaultSleepHours}h sleep started!", Toast.LENGTH_SHORT).show()
            window.decorView.postDelayed({ refreshStatus() }, 500)
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

        findViewById<Button>(R.id.btnTestPhoneAlarm).setOnClickListener {
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
            val intent = Intent(this, com.wakemeup.receiver.AlarmTriggerReceiver::class.java)
            val pendingIntent = android.app.PendingIntent.getBroadcast(
                this,
                999,
                intent,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
            )
            val ringAt = System.currentTimeMillis() + 5000L
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(
                    android.app.AlarmManager.RTC_WAKEUP,
                    ringAt,
                    pendingIntent
                )
            } else {
                alarmManager.setExact(
                    android.app.AlarmManager.RTC_WAKEUP,
                    ringAt,
                    pendingIntent
                )
            }
            Toast.makeText(this, "Alarm test scheduled! Ringing in 5 seconds...", Toast.LENGTH_SHORT).show()
        }

        findViewById<Button>(R.id.btnTest1MinSleep).setOnClickListener {
            val intent = Intent(this, SleepDetectionService::class.java).apply {
                action = SleepDetectionService.ACTION_MANUAL_SLEEP
                putExtra(SleepDetectionService.EXTRA_DURATION_MINUTES, 1.0)
            }
            startService(intent)
            Toast.makeText(this, "1-minute test sleep started! Alarm set for 60s from now.", Toast.LENGTH_LONG).show()
            window.decorView.postDelayed({ refreshStatus() }, 500)
        }

        findViewById<Button>(R.id.btnStopSleep).setOnClickListener {
            val intent = Intent(this, SleepDetectionService::class.java).apply {
                action = SleepDetectionService.ACTION_STOP_SLEEP
            }
            startService(intent)
            Toast.makeText(this, "Sleep stopped", Toast.LENGTH_SHORT).show()
            refreshStatus()
        }

        // Setup Checklist buttons
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

        // Screen Message / Ambient Canvas Billboard bindings
        etScreenMessage = findViewById(R.id.etScreenMessage)
        etCanvasSubtitle = findViewById(R.id.etCanvasSubtitle)
        chipGroupRecentMessages = findViewById(R.id.chipGroupRecentMessages)
        spTargetDisplay = findViewById(R.id.spTargetDisplay)
        rgMessageDuration = findViewById(R.id.rgMessageDuration)
        rbPersistent = findViewById(R.id.rbPersistent)
        rbLockPhoneOnly = findViewById(R.id.rbLockPhoneOnly)
        rbToast15s = findViewById(R.id.rbToast15s)
        rbToast30s = findViewById(R.id.rbToast30s)
        btnSendMessage = findViewById(R.id.btnSendMessage)
        btnDismissScreenMessage = findViewById(R.id.btnDismissScreenMessage)
        tvActiveMessageStatus = findViewById(R.id.tvActiveMessageStatus)

        // Prefill last typed or sent message
        val prefs = getSharedPreferences("WakeMeUpPrefs", Context.MODE_PRIVATE)
        val lastSavedMsg = prefs.getString(PREFS_KEY_LAST_MESSAGE, null) ?: defaultMessages.first()
        etScreenMessage.setText(lastSavedMsg)
        etScreenMessage.setSelection(lastSavedMsg.length)

        etScreenMessage.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                s?.toString()?.let { saveLastTypedMessage(it) }
            }
        })

        populateRecentMessageChips(getMessageHistory())

        val defaultAdapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, listOf("All Displays (Mirrored)"))
        spTargetDisplay.adapter = defaultAdapter

        btnSendMessage.setOnClickListener {
            val text = etScreenMessage.text.toString().trim()
            if (text.isEmpty()) {
                Toast.makeText(this, "Please type a message first", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            val subtitle = etCanvasSubtitle.text.toString().trim().ifEmpty { null }

            // Remember message in persistent history
            saveMessageToHistory(text)

            val selectedIndex = spTargetDisplay.selectedItemPosition
            val targetDisplayId = if (selectedIndex <= 0 || selectedIndex > connectedDisplays.size) {
                "all"
            } else {
                connectedDisplays[selectedIndex - 1].id
            }

            val dismissPolicy = if (rbLockPhoneOnly.isChecked) "phone_only" else "esc_any"
            val durationSeconds = when {
                rbToast15s.isChecked -> 15
                rbToast30s.isChecked -> 30
                else -> null
            }

            lifecycleScope.launch {
                val res = syncClient.sendCanvas(
                    type = "billboard",
                    title = text,
                    subtitle = subtitle,
                    dismissPolicy = dismissPolicy,
                    targetDisplayId = targetDisplayId,
                    durationSeconds = durationSeconds
                )
                if (res.isSuccess) {
                    val policyTag = if (dismissPolicy == "phone_only") " [🔒 LOCKED]" else ""
                    val durationLabel = if (durationSeconds != null) "${durationSeconds}s toast" else "persistent"
                    Toast.makeText(this@MainActivity, "Sent to Mac ($durationLabel$policyTag)!", Toast.LENGTH_SHORT).show()
                    tvActiveMessageStatus.visibility = View.VISIBLE
                    tvActiveMessageStatus.text = "Active on Screen: \"${text.take(30)}${if (text.length > 30) "..." else ""}\"$policyTag"
                    loadDisplays()
                } else {
                    Toast.makeText(this@MainActivity, "Failed: ${res.exceptionOrNull()?.message}", Toast.LENGTH_LONG).show()
                }
            }
        }

        btnDismissScreenMessage.setOnClickListener {
            val selectedIndex = spTargetDisplay.selectedItemPosition
            val targetDisplayId = if (selectedIndex <= 0 || selectedIndex > connectedDisplays.size) {
                "all"
            } else {
                connectedDisplays[selectedIndex - 1].id
            }

            lifecycleScope.launch {
                val res = syncClient.dismissCanvas(targetDisplayId)
                if (res.isSuccess) {
                    Toast.makeText(this@MainActivity, "Screen cleared", Toast.LENGTH_SHORT).show()
                    tvActiveMessageStatus.visibility = View.GONE
                    loadDisplays()
                } else {
                    Toast.makeText(this@MainActivity, "Failed to clear: ${res.exceptionOrNull()?.message}", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    private fun getMessageHistory(): List<String> {
        val prefs = getSharedPreferences("WakeMeUpPrefs", Context.MODE_PRIVATE)
        val jsonStr = prefs.getString(PREFS_KEY_MESSAGE_HISTORY, null)
        if (!jsonStr.isNullOrEmpty()) {
            try {
                val array = JSONArray(jsonStr)
                val list = mutableListOf<String>()
                for (i in 0 until array.length()) {
                    val s = array.getString(i).trim()
                    if (s.isNotEmpty() && !list.contains(s)) {
                        list.add(s)
                    }
                }
                if (list.isNotEmpty()) return list
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        return defaultMessages
    }

    private fun saveMessageToHistory(message: String) {
        val trimmed = message.trim()
        if (trimmed.isEmpty()) return

        val prefs = getSharedPreferences("WakeMeUpPrefs", Context.MODE_PRIVATE)
        val currentHistory = getMessageHistory().toMutableList()
        currentHistory.remove(trimmed)
        currentHistory.add(0, trimmed) // Most recent first
        val limited = currentHistory.take(20)

        val array = JSONArray()
        for (item in limited) {
            array.put(item)
        }

        prefs.edit()
            .putString(PREFS_KEY_LAST_MESSAGE, trimmed)
            .putString(PREFS_KEY_MESSAGE_HISTORY, array.toString())
            .apply()

        populateRecentMessageChips(limited)
    }

    private fun saveLastTypedMessage(message: String) {
        val trimmed = message.trim()
        if (trimmed.isEmpty()) return
        val prefs = getSharedPreferences("WakeMeUpPrefs", Context.MODE_PRIVATE)
        prefs.edit().putString(PREFS_KEY_LAST_MESSAGE, trimmed).apply()
    }

    private fun populateRecentMessageChips(history: List<String>) {
        chipGroupRecentMessages.removeAllViews()
        for (msg in history) {
            val chip = Chip(this).apply {
                text = msg
                isClickable = true
                isCheckable = false
                chipBackgroundColor = ColorStateList.valueOf(Color.parseColor("#2C2C2E"))
                setTextColor(Color.parseColor("#E5E5EA"))
                chipStrokeColor = ColorStateList.valueOf(Color.parseColor("#3A3A3C"))
                chipStrokeWidth = 2f
                textSize = 12f
                setOnClickListener {
                    etScreenMessage.setText(msg)
                    etScreenMessage.setSelection(msg.length)
                    saveLastTypedMessage(msg)
                }
            }
            chipGroupRecentMessages.addView(chip)
        }
    }

    private fun loadDisplays() {
        lifecycleScope.launch {
            val res = syncClient.fetchDisplays()
            if (res.isSuccess) {
                val displays = res.getOrNull() ?: emptyList()
                connectedDisplays = displays
                val displayNames = mutableListOf("All Displays (Mirrored)")
                for (d in displays) {
                    val modeTag = if (d.activeMode != "idle") " [${d.activeMode.uppercase()}]" else ""
                    val mainTag = if (d.isMain) " (Main)" else ""
                    displayNames.add("${d.name}$mainTag$modeTag")
                }
                val adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, displayNames)
                val currentPos = spTargetDisplay.selectedItemPosition
                spTargetDisplay.adapter = adapter
                if (currentPos < displayNames.size) {
                    spTargetDisplay.setSelection(currentPos)
                }
            }
        }
    }

    private fun formatHour(hour: Int): String {
        return SleepDetectionService.formatHour(hour)
    }

    private fun syncConfigFromMac() {
        lifecycleScope.launch {
            val res = syncClient.fetchConfig()
            if (res.isSuccess) {
                val config = res.getOrThrow()
                SleepDetectionService.saveSleepConfig(this@MainActivity, config)
                refreshStatus()
                Toast.makeText(this@MainActivity, "Preferences locked & synced with Mac!", Toast.LENGTH_SHORT).show()
            }
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

        val config = SleepDetectionService.getSleepConfig(this)
        tvSleepDuration.text = "Target Duration: ${config.defaultSleepHours} hours"
        tvSleepWindow.text = "Eligible Sleep Window: ${formatHour(config.sleepWindowStartHour)} – ${formatHour(config.sleepWindowEndHour)}"
        tvAutoPushWindow.text = "Auto-Push Window: ${formatHour(config.autoPushWindowStartHour)} – ${formatHour(config.autoPushWindowEndHour)}"

        isUpdatingAwaySwitch = true
        switchAwayMode.isChecked = config.isAwayMode
        isUpdatingAwaySwitch = false

        val targetMs = SleepDetectionService.getActiveTargetWakeMs(this)
        if (targetMs != null) {
            val timeFormat = SimpleDateFormat("h:mm a", Locale.getDefault())
            tvSleepStatus.text = "Status: Sleeping"
            tvWakeTarget.text = "Target Wake Up: ${timeFormat.format(Date(targetMs))} (${config.defaultSleepHours}h)"
        } else if (config.isAwayMode) {
            tvSleepStatus.text = "Status: Away Mode (Paused)"
            tvWakeTarget.text = "Target: Standby"
        } else {
            val calendar = java.util.Calendar.getInstance()
            val currentHour = calendar.get(java.util.Calendar.HOUR_OF_DAY)
            val isEligible = SleepDetectionService.isHourInWindow(currentHour, config.sleepWindowStartHour, config.sleepWindowEndHour)
            if (isEligible) {
                tvSleepStatus.text = "Status: Monitoring Lock Events (Active Window)"
            } else {
                tvSleepStatus.text = "Status: Standby (Outside Sleep Window)"
            }
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

    private fun discoverMac() {
        lifecycleScope.launch {
            Toast.makeText(this@MainActivity, "Searching for Mac via Bonjour & Subnet scan...", Toast.LENGTH_SHORT).show()
            val result = syncClient.autoDiscoverMac(timeoutMs = 4000)
            if (result.isSuccess) {
                val ip = result.getOrNull()
                etMacHost.setText(ip)
                Toast.makeText(this@MainActivity, "Discovered Mac at $ip!", Toast.LENGTH_LONG).show()
            } else {
                Toast.makeText(this@MainActivity, "Discovery failed: ${result.exceptionOrNull()?.message}", Toast.LENGTH_LONG).show()
            }
        }
    }
}
