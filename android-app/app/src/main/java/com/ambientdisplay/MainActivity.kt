package com.ambientdisplay

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.LayoutInflater
import android.view.View
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.chip.Chip
import com.google.android.material.chip.ChipGroup
import com.google.android.material.materialswitch.MaterialSwitch
import com.ambientdisplay.auth.AuthManager
import com.ambientdisplay.cloud.CloudDevice
import com.ambientdisplay.cloud.DeviceSyncManager
import com.ambientdisplay.detector.InactivityCompensator
import com.ambientdisplay.network.MacSyncClient
import com.ambientdisplay.service.SleepDetectionService
import com.ambientdisplay.util.OEMPowerHelper
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONTokener
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : AppCompatActivity() {

    private lateinit var syncClient: MacSyncClient
    private lateinit var authManager: AuthManager
    private lateinit var deviceSyncManager: DeviceSyncManager

    // Top Header & Bottom Navigation
    private lateinit var tvHeaderSyncIndicator: TextView
    private lateinit var bottomNavigation: BottomNavigationView
    private lateinit var tabSleep: ScrollView
    private lateinit var tabCanvas: ScrollView
    private lateinit var tabDevices: ScrollView
    private lateinit var tabSettings: ScrollView

    // TAB 1: Sleep & Alarm Views
    private lateinit var tvSleepStatus: TextView
    private lateinit var tvWakeTarget: TextView
    private lateinit var tvDisplayTimeout: TextView
    private lateinit var chipGroupSleepDuration: ChipGroup
    private lateinit var btnManualSleep: Button
    private lateinit var btnStopSleep: Button
    private lateinit var switchAwayMode: MaterialSwitch
    private var isUpdatingAwaySwitch = false
    private var selectedSleepDuration: Double = 7.5

    // TAB 2: Canvas Billboard Views
    private lateinit var spCanvasType: Spinner
    private lateinit var etScreenMessage: EditText
    private lateinit var etCanvasSubtitle: EditText
    private lateinit var etMediaUrl: EditText
    private lateinit var chipGroupRecentMessages: ChipGroup
    private lateinit var spTargetDisplay: Spinner
    private lateinit var rgMessageDuration: RadioGroup
    private lateinit var rbPersistent: RadioButton
    private lateinit var rbLockPhoneOnly: RadioButton
    private lateinit var rbToast15s: RadioButton
    private lateinit var rbToast30s: RadioButton
    private lateinit var btnSendMessage: Button
    private lateinit var btnDismissScreenMessage: Button
    private lateinit var tvActiveMessageStatus: TextView
    private var connectedDisplays: List<MacSyncClient.DisplayInfo> = emptyList()

    // TAB 3: Devices & Fleet Views
    private lateinit var tvCloudAuthStatus: TextView
    private lateinit var btnGoogleSignIn: Button
    private lateinit var btnSignOut: Button
    private lateinit var layoutFleetHeader: LinearLayout
    private lateinit var tvCloudDevicesHeader: TextView
    private lateinit var cbSelectAllFleet: CheckBox
    private lateinit var layoutFleetDeviceList: LinearLayout
    private lateinit var tvFleetEmptyState: TextView
    private lateinit var etMacHost: EditText
    private var cloudDevices: List<CloudDevice> = emptyList()
    private val selectedFleetDeviceIds = mutableSetOf<String>()

    // TAB 4: Settings Views (Menu Bar App Parity)
    private lateinit var etSettingSleepHours: EditText
    private lateinit var btnSleepMinus: Button
    private lateinit var btnSleepPlus: Button
    private lateinit var tvSleepDuration: TextView
    private lateinit var tvSleepWindow: TextView
    private lateinit var spSleepStartHour: Spinner
    private lateinit var spSleepEndHour: Spinner
    private lateinit var tvAutoPushWindow: TextView
    private lateinit var spAutoPushStartHour: Spinner
    private lateinit var spAutoPushEndHour: Spinner
    private lateinit var switchAutoDetectInactivity: MaterialSwitch
    private lateinit var layoutCustomOffset: LinearLayout
    private lateinit var etInactivityOffset: EditText
    private lateinit var btnOffsetMinus: Button
    private lateinit var btnOffsetPlus: Button
    private lateinit var viewNightColorPreview: View
    private lateinit var etNightColorHex: EditText
    private lateinit var viewDawnColorPreview: View
    private lateinit var etDawnColorHex: EditText
    private lateinit var viewWakeColorPreview: View
    private lateinit var etWakeColorHex: EditText
    private lateinit var btnResetAmbientDefaults: Button
    private var isProgrammaticUpdate = false
    private var syncDebounceJob: kotlinx.coroutines.Job? = null

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
            startSleepService()
            checkInitialSetupPermissions()
        }

    private val googleSignInLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val data = result.data
            if (data != null) {
                val task = GoogleSignIn.getSignedInAccountFromIntent(data)
                lifecycleScope.launch {
                    val authRes = authManager.handleSignInResult(task)
                    if (authRes.isSuccess) {
                        Toast.makeText(this@MainActivity, "Signed in with Google!", Toast.LENGTH_SHORT).show()
                        updateCloudAuthUI()
                    } else {
                        Toast.makeText(this@MainActivity, "Google Sign-in failed: ${authRes.exceptionOrNull()?.message}", Toast.LENGTH_LONG).show()
                    }
                }
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        syncClient = MacSyncClient(this)
        authManager = AuthManager(this)
        deviceSyncManager = DeviceSyncManager(this)

        initViews()
        setupBottomNavigation()
        setupSleepTabControls()
        setupCanvasTabControls()
        setupDevicesTabControls()
        setupSettingsTabControls()

        checkNotificationPermission()
        refreshStatus()
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
        checkInitialSetupPermissions()
    }

    private fun checkInitialSetupPermissions() {
        val prefs = SleepDetectionService.getPrefs(this)

        // 1. Battery Optimization (critical for background sleep tracking & alarm wakeup)
        if (!OEMPowerHelper.isIgnoringBatteryOptimizations(this)) {
            val askedBattery = prefs.getBoolean("asked_battery_opt", false)
            if (!askedBattery) {
                prefs.edit().putBoolean("asked_battery_opt", true).apply()
                com.google.android.material.dialog.MaterialAlertDialogBuilder(this)
                    .setTitle("Unrestricted Battery Access")
                    .setMessage("To ensure sleep detection and alarms fire reliably without being killed during deep sleep, please allow unrestricted background activity.")
                    .setPositiveButton("Configure") { _, _ ->
                        OEMPowerHelper.requestIgnoreBatteryOptimizations(this)
                    }
                    .setNegativeButton("Later", null)
                    .show()
                return
            }
        }

        // 2. Exact Alarms check for Android 12+ (API 31+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
            if (!alarmManager.canScheduleExactAlarms()) {
                val askedAlarm = prefs.getBoolean("asked_exact_alarm", false)
                if (!askedAlarm) {
                    prefs.edit().putBoolean("asked_exact_alarm", true).apply()
                    com.google.android.material.dialog.MaterialAlertDialogBuilder(this)
                        .setTitle("Exact Alarms Permission")
                        .setMessage("Android requires permission to schedule exact wake-up alarms and sleep window transitions.")
                        .setPositiveButton("Allow") { _, _ ->
                            try {
                                startActivity(Intent(android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                                    data = android.net.Uri.parse("package:$packageName")
                                })
                            } catch (_: Exception) {}
                        }
                        .setNegativeButton("Later", null)
                        .show()
                    return
                }
            }
        }

        // 3. OEM Auto-Launch / Background restrictions for aggressive manufacturers
        if (OEMPowerHelper.isAggressiveOEM()) {
            val askedAutoLaunch = prefs.getBoolean("asked_autolaunch", false)
            if (!askedAutoLaunch) {
                prefs.edit().putBoolean("asked_autolaunch", true).apply()
                com.google.android.material.dialog.MaterialAlertDialogBuilder(this)
                    .setTitle(OEMPowerHelper.getAutoLaunchTitle())
                    .setMessage(OEMPowerHelper.getAutoLaunchMessage())
                    .setPositiveButton("Open Settings") { _, _ ->
                        OEMPowerHelper.openAutoLaunchSettings(this)
                    }
                    .setNegativeButton("Later", null)
                    .show()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
        loadDisplays()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            checkInitialSetupPermissions()
        }
    }

    private fun initViews() {
        tvHeaderSyncIndicator = findViewById(R.id.tvHeaderSyncIndicator)
        bottomNavigation = findViewById(R.id.bottomNavigation)
        tabSleep = findViewById(R.id.tabSleep)
        tabCanvas = findViewById(R.id.tabCanvas)
        tabDevices = findViewById(R.id.tabDevices)
        tabSettings = findViewById(R.id.tabSettings)

        // Tab 1 Views
        tvSleepStatus = findViewById(R.id.tvSleepStatus)
        tvWakeTarget = findViewById(R.id.tvWakeTarget)
        tvDisplayTimeout = findViewById(R.id.tvDisplayTimeout)
        chipGroupSleepDuration = findViewById(R.id.chipGroupSleepDuration)
        btnManualSleep = findViewById(R.id.btnManualSleep)
        btnStopSleep = findViewById(R.id.btnStopSleep)
        switchAwayMode = findViewById(R.id.switchAwayMode)

        // Tab 2 Views
        spCanvasType = findViewById(R.id.spCanvasType)
        etScreenMessage = findViewById(R.id.etScreenMessage)
        etCanvasSubtitle = findViewById(R.id.etCanvasSubtitle)
        etMediaUrl = findViewById(R.id.etMediaUrl)
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

        // Tab 3 Views
        tvCloudAuthStatus = findViewById(R.id.tvCloudAuthStatus)
        btnGoogleSignIn = findViewById(R.id.btnGoogleSignIn)
        btnSignOut = findViewById(R.id.btnSignOut)
        layoutFleetHeader = findViewById(R.id.layoutFleetHeader)
        tvCloudDevicesHeader = findViewById(R.id.tvCloudDevicesHeader)
        cbSelectAllFleet = findViewById(R.id.cbSelectAllFleet)
        layoutFleetDeviceList = findViewById(R.id.layoutFleetDeviceList)
        tvFleetEmptyState = findViewById(R.id.tvFleetEmptyState)
        etMacHost = findViewById(R.id.etMacHost)

        // Tab 4 Views
        etSettingSleepHours = findViewById(R.id.etSettingSleepHours)
        btnSleepMinus = findViewById(R.id.btnSleepMinus)
        btnSleepPlus = findViewById(R.id.btnSleepPlus)
        tvSleepDuration = findViewById(R.id.tvSleepDuration)
        tvSleepWindow = findViewById(R.id.tvSleepWindow)
        spSleepStartHour = findViewById(R.id.spSleepStartHour)
        spSleepEndHour = findViewById(R.id.spSleepEndHour)
        tvAutoPushWindow = findViewById(R.id.tvAutoPushWindow)
        spAutoPushStartHour = findViewById(R.id.spAutoPushStartHour)
        spAutoPushEndHour = findViewById(R.id.spAutoPushEndHour)
        switchAutoDetectInactivity = findViewById(R.id.switchAutoDetectInactivity)
        layoutCustomOffset = findViewById(R.id.layoutCustomOffset)
        etInactivityOffset = findViewById(R.id.etInactivityOffset)
        btnOffsetMinus = findViewById(R.id.btnOffsetMinus)
        btnOffsetPlus = findViewById(R.id.btnOffsetPlus)
        viewNightColorPreview = findViewById(R.id.viewNightColorPreview)
        etNightColorHex = findViewById(R.id.etNightColorHex)
        viewDawnColorPreview = findViewById(R.id.viewDawnColorPreview)
        etDawnColorHex = findViewById(R.id.etDawnColorHex)
        viewWakeColorPreview = findViewById(R.id.viewWakeColorPreview)
        etWakeColorHex = findViewById(R.id.etWakeColorHex)
        btnResetAmbientDefaults = findViewById(R.id.btnResetAmbientDefaults)
    }

    private fun setupBottomNavigation() {
        bottomNavigation.setOnItemSelectedListener { item ->
            when (item.itemId) {
                R.id.nav_sleep -> {
                    tabSleep.visibility = View.VISIBLE
                    tabCanvas.visibility = View.GONE
                    tabDevices.visibility = View.GONE
                    tabSettings.visibility = View.GONE
                    refreshStatus()
                    true
                }
                R.id.nav_canvas -> {
                    tabSleep.visibility = View.GONE
                    tabCanvas.visibility = View.VISIBLE
                    tabDevices.visibility = View.GONE
                    tabSettings.visibility = View.GONE
                    loadDisplays()
                    true
                }
                R.id.nav_devices -> {
                    tabSleep.visibility = View.GONE
                    tabCanvas.visibility = View.GONE
                    tabDevices.visibility = View.VISIBLE
                    tabSettings.visibility = View.GONE
                    true
                }
                R.id.nav_settings -> {
                    tabSleep.visibility = View.GONE
                    tabCanvas.visibility = View.GONE
                    tabDevices.visibility = View.GONE
                    tabSettings.visibility = View.VISIBLE
                    refreshStatus()
                    true
                }
                else -> false
            }
        }
    }

    private fun setupSleepTabControls() {
        chipGroupSleepDuration.setOnCheckedStateChangeListener { _, checkedIds ->
            if (checkedIds.isEmpty() || isProgrammaticUpdate) return@setOnCheckedStateChangeListener
            selectedSleepDuration = when (checkedIds.first()) {
                R.id.chipDuration6 -> 6.0
                R.id.chipDuration7 -> 7.0
                R.id.chipDuration75 -> 7.5
                R.id.chipDuration8 -> 8.0
                R.id.chipDuration9 -> 9.0
                else -> 7.5
            }
            btnManualSleep.text = "🌙 Start Sleep Session (${selectedSleepDuration}h)"
            etSettingSleepHours.setText(String.format(Locale.US, "%.1f", selectedSleepDuration))
            tvSleepDuration.text = "Target Duration: ${String.format(Locale.US, "%.1f", selectedSleepDuration)} hours"
            autoSyncPreferences(debounceMs = 0L)
        }

        btnManualSleep.setOnClickListener {
            val intent = Intent(this, SleepDetectionService::class.java).apply {
                action = SleepDetectionService.ACTION_MANUAL_SLEEP
                putExtra(SleepDetectionService.EXTRA_DURATION_MINUTES, selectedSleepDuration * 60.0)
            }
            ContextCompat.startForegroundService(this, intent)
            Toast.makeText(this, "Manual ${selectedSleepDuration}h sleep session started!", Toast.LENGTH_SHORT).show()
            window.decorView.postDelayed({ refreshStatus() }, 500)
        }

        btnStopSleep.setOnClickListener {
            val intent = Intent(this, SleepDetectionService::class.java).apply {
                action = SleepDetectionService.ACTION_STOP_SLEEP
            }
            startService(intent)
            Toast.makeText(this, "Sleep stopped", Toast.LENGTH_SHORT).show()
            refreshStatus()
        }

        switchAwayMode.setOnCheckedChangeListener { _, isChecked ->
            if (isUpdatingAwaySwitch) return@setOnCheckedChangeListener
            val config = SleepDetectionService.getSleepConfig(this)
            val updated = config.copy(isAwayMode = isChecked)
            SleepDetectionService.saveSleepConfig(this, updated)

            if (isChecked) {
                val stopIntent = Intent(this, SleepDetectionService::class.java).apply {
                    action = SleepDetectionService.ACTION_STOP_SERVICE
                }
                startService(stopIntent)
            } else {
                startSleepService()
            }
            refreshStatus()

            if (authManager.currentUser != null) {
                deviceSyncManager.savePreferencesToCloud(updated)
            } else {
                lifecycleScope.launch {
                    try { syncClient.sendAwayEvent(isChecked) } catch (_: Exception) {}
                }
            }
        }

        findViewById<Button>(R.id.btnTestPhoneAlarm).setOnClickListener {
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
            val intent = Intent(this, com.ambientdisplay.receiver.AlarmTriggerReceiver::class.java)
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
            ContextCompat.startForegroundService(this, intent)
            Toast.makeText(this, "1-minute test sleep started! Alarm set for 60s from now.", Toast.LENGTH_LONG).show()
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
    }

    private fun setupCanvasTabControls() {
        val canvasTypes = listOf(
            "Billboard (Typography)",
            "Ambient Image Poster",
            "Looping Ambient Video",
            "Web Dashboard / URL"
        )
        val canvasTypeAdapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, canvasTypes)
        spCanvasType.adapter = canvasTypeAdapter

        val prefs = SleepDetectionService.getPrefs(this)
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
            val subtitle = etCanvasSubtitle.text.toString().trim().ifEmpty { null }
            val mediaUrl = etMediaUrl.text.toString().trim().ifEmpty { null }

            val canvasType = when (spCanvasType.selectedItemPosition) {
                1 -> "image"
                2 -> "video"
                3 -> "webview"
                else -> "billboard"
            }

            if (text.isEmpty() && mediaUrl.isNullOrEmpty()) {
                Toast.makeText(this, "Please provide a headline or media URL", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }

            if (text.isNotEmpty()) {
                saveMessageToHistory(text)
            }

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
                    type = canvasType,
                    title = if (text.isNotEmpty()) text else (mediaUrl ?: "Ambient Display"),
                    subtitle = subtitle,
                    mediaUrl = mediaUrl,
                    dismissPolicy = dismissPolicy,
                    targetDisplayId = targetDisplayId,
                    durationSeconds = durationSeconds
                )
                if (res.isSuccess) {
                    val policyTag = if (dismissPolicy == "phone_only") " [🔒 LOCKED]" else ""
                    Toast.makeText(this@MainActivity, "Sent to Mac ($canvasType$policyTag)!", Toast.LENGTH_SHORT).show()
                    tvActiveMessageStatus.visibility = View.VISIBLE
                    tvActiveMessageStatus.text = "Active on Screen: \"${(text.ifEmpty { mediaUrl ?: "" }).take(30)}\"$policyTag"
                    loadDisplays()
                } else {
                    Toast.makeText(this@MainActivity, "Failed: ${res.exceptionOrNull()?.message}", Toast.LENGTH_LONG).show()
                }
            }

            if (authManager.currentUser != null) {
                val cloudPayload = hashMapOf<String, Any>(
                    "type" to canvasType,
                    "title" to (if (text.isNotEmpty()) text else (mediaUrl ?: "Ambient Display")),
                    "subtitle" to (subtitle ?: ""),
                    "media_url" to (mediaUrl ?: ""),
                    "dismiss_policy" to dismissPolicy,
                    "target_display_id" to targetDisplayId,
                    "created_at" to com.google.firebase.Timestamp.now()
                )
                val targetIds = if (cbSelectAllFleet.isChecked || selectedFleetDeviceIds.isEmpty()) {
                    listOf("all")
                } else {
                    selectedFleetDeviceIds.toList()
                }
                lifecycleScope.launch {
                    val count = if (targetIds.contains("all")) cloudDevices.size else targetIds.size
                    val ok = deviceSyncManager.sendCanvasToDevices(targetIds, cloudPayload)
                    if (ok) {
                        Toast.makeText(this@MainActivity, "Cloud broadcast to $count device(s) dispatched!", Toast.LENGTH_SHORT).show()
                    }
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

            if (authManager.currentUser != null) {
                val targetIds = if (cbSelectAllFleet.isChecked || selectedFleetDeviceIds.isEmpty()) {
                    listOf("all")
                } else {
                    selectedFleetDeviceIds.toList()
                }
                lifecycleScope.launch {
                    deviceSyncManager.clearCanvasOnDevices(targetIds)
                }
            }
        }
    }

    private fun setupDevicesTabControls() {
        btnGoogleSignIn.setOnClickListener {
            googleSignInLauncher.launch(authManager.getSignInIntent())
        }

        btnSignOut.setOnClickListener {
            authManager.signOut {
                deviceSyncManager.stopListening()
                updateCloudAuthUI()
                Toast.makeText(this, "Signed out", Toast.LENGTH_SHORT).show()
            }
        }

        updateCloudAuthUI()
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

        findViewById<Button>(R.id.btnAutoDiscover).setOnClickListener {
            discoverMac()
        }
    }

    private fun setupSettingsTabControls() {
        val hoursList = (0..23).map { formatHour(it) }
        val hourAdapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, hoursList)
        spSleepStartHour.adapter = hourAdapter
        spSleepEndHour.adapter = hourAdapter
        spAutoPushStartHour.adapter = hourAdapter
        spAutoPushEndHour.adapter = hourAdapter

        val spinnerListener = object : android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) {
                if (!isProgrammaticUpdate) {
                    val sStart = spSleepStartHour.selectedItemPosition
                    val sEnd = spSleepEndHour.selectedItemPosition
                    tvSleepWindow.text = "Eligible Sleep Window: ${formatHour(sStart)} – ${formatHour(sEnd)}"
                    val pStart = spAutoPushStartHour.selectedItemPosition
                    val pEnd = spAutoPushEndHour.selectedItemPosition
                    tvAutoPushWindow.text = "Auto-Push Window: ${formatHour(pStart)} – ${formatHour(pEnd)}"
                    autoSyncPreferences(debounceMs = 150L)
                }
            }
            override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {}
        }
        spSleepStartHour.onItemSelectedListener = spinnerListener
        spSleepEndHour.onItemSelectedListener = spinnerListener
        spAutoPushStartHour.onItemSelectedListener = spinnerListener
        spAutoPushEndHour.onItemSelectedListener = spinnerListener

        etSettingSleepHours.setOnFocusChangeListener { _, hasFocus ->
            if (!hasFocus) {
                val v = etSettingSleepHours.text.toString().toDoubleOrNull()
                if (v != null && v in 1.0..16.0) {
                    tvSleepDuration.text = "Target Duration: ${String.format(Locale.US, "%.1f", v)} hours"
                    autoSyncPreferences(debounceMs = 0L)
                }
            }
        }

        btnSleepMinus.setOnClickListener {
            val current = etSettingSleepHours.text.toString().toDoubleOrNull() ?: 7.5
            val updated = (current - 0.5).coerceIn(1.0, 16.0)
            etSettingSleepHours.setText(String.format(Locale.US, "%.1f", updated))
            tvSleepDuration.text = "Target Duration: ${String.format(Locale.US, "%.1f", updated)} hours"
            autoSyncPreferences(debounceMs = 0L)
        }

        btnSleepPlus.setOnClickListener {
            val current = etSettingSleepHours.text.toString().toDoubleOrNull() ?: 7.5
            val updated = (current + 0.5).coerceIn(1.0, 16.0)
            etSettingSleepHours.setText(String.format(Locale.US, "%.1f", updated))
            tvSleepDuration.text = "Target Duration: ${String.format(Locale.US, "%.1f", updated)} hours"
            autoSyncPreferences(debounceMs = 0L)
        }

        switchAutoDetectInactivity.setOnCheckedChangeListener { _, isChecked ->
            layoutCustomOffset.visibility = if (isChecked) View.GONE else View.VISIBLE
            if (!isProgrammaticUpdate) {
                autoSyncPreferences(debounceMs = 0L)
            }
        }

        btnOffsetMinus.setOnClickListener {
            val current = etInactivityOffset.text.toString().toIntOrNull() ?: 30
            val updated = (current - 5).coerceIn(0, 120)
            etInactivityOffset.setText(updated.toString())
            autoSyncPreferences(debounceMs = 0L)
        }

        btnOffsetPlus.setOnClickListener {
            val current = etInactivityOffset.text.toString().toIntOrNull() ?: 30
            val updated = (current + 5).coerceIn(0, 120)
            etInactivityOffset.setText(updated.toString())
            autoSyncPreferences(debounceMs = 0L)
        }

        // Color Hex input listeners
        fun attachColorWatcher(editText: EditText, previewView: View, fallbackHex: String) {
            editText.addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    val hex = s?.toString()?.trim() ?: fallbackHex
                    updateColorPreview(previewView, hex, Color.parseColor(fallbackHex))
                    if (!isProgrammaticUpdate && hex.length == 7 && hex.startsWith("#")) {
                        autoSyncPreferences(debounceMs = 400L)
                    }
                }
            })
        }

        attachColorWatcher(etNightColorHex, viewNightColorPreview, "#D95926")
        attachColorWatcher(etDawnColorHex, viewDawnColorPreview, "#FA7268")
        attachColorWatcher(etWakeColorHex, viewWakeColorPreview, "#FFD000")

        btnResetAmbientDefaults.setOnClickListener {
            etNightColorHex.setText("#D95926")
            etDawnColorHex.setText("#FA7268")
            etWakeColorHex.setText("#FFD000")
            autoSyncPreferences(debounceMs = 0L)
        }

        // Checklist buttons
        findViewById<Button>(R.id.btnBatteryOpt).setOnClickListener {
            OEMPowerHelper.requestIgnoreBatteryOptimizations(this)
        }

        findViewById<Button>(R.id.btnUsageAccess).setOnClickListener {
            OEMPowerHelper.openUsageStatsSettings(this)
        }

        findViewById<Button>(R.id.btnAccessibility).setOnClickListener {
            OEMPowerHelper.openAccessibilitySettings(this)
        }

        findViewById<Button>(R.id.btnAutoLaunch).setOnClickListener {
            OEMPowerHelper.openAutoLaunchSettings(this)
        }
    }

    private fun updateColorPreview(view: View, hex: String, fallbackColor: Int) {
        val color = try {
            Color.parseColor(hex.trim())
        } catch (_: Exception) {
            fallbackColor
        }
        val drawable = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(color)
            setStroke(2, Color.parseColor("#3A3A3C"))
        }
        view.background = drawable
    }

    private fun autoSyncPreferences(debounceMs: Long = 300L) {
        syncDebounceJob?.cancel()
        syncDebounceJob = lifecycleScope.launch {
            if (debounceMs > 0) {
                kotlinx.coroutines.delay(debounceMs)
            }
            val hours = etSettingSleepHours.text.toString().toDoubleOrNull() ?: 7.5
            val sleepStart = spSleepStartHour.selectedItemPosition
            val sleepEnd = spSleepEndHour.selectedItemPosition
            val autoPushStart = spAutoPushStartHour.selectedItemPosition
            val autoPushEnd = spAutoPushEndHour.selectedItemPosition
            val autoDetect = switchAutoDetectInactivity.isChecked
            val offset = etInactivityOffset.text.toString().toDoubleOrNull() ?: 30.0
            val isAway = switchAwayMode.isChecked
            val nightHex = etNightColorHex.text.toString().trim().ifEmpty { "#D95926" }
            val dawnHex = etDawnColorHex.text.toString().trim().ifEmpty { "#FA7268" }
            val wakeHex = etWakeColorHex.text.toString().trim().ifEmpty { "#FFD000" }

            val newConfig = MacSyncClient.AppConfig(
                defaultSleepHours = hours,
                sleepWindowStartHour = sleepStart,
                sleepWindowEndHour = sleepEnd,
                autoPushWindowStartHour = autoPushStart,
                autoPushWindowEndHour = autoPushEnd,
                inactivityOffsetMinutes = offset,
                autoDetectInactivity = autoDetect,
                isAwayMode = isAway,
                ambientNightColorHex = nightHex,
                ambientDawnColorHex = dawnHex,
                ambientWakeColorHex = wakeHex
            )

            // 1. Save locally immediately
            SleepDetectionService.saveSleepConfig(this@MainActivity, newConfig)

            // 2. Quietly push to Cloud Firestore
            if (authManager.currentUser != null) {
                deviceSyncManager.savePreferencesToCloud(newConfig)
            }

            // 3. Quietly push to Mac server via LAN HTTP
            try {
                syncClient.sendConfig(newConfig)
            } catch (_: Exception) {}
        }
    }

    private fun getMessageHistory(): List<String> {
        val prefs = SleepDetectionService.getPrefs(this)
        val jsonStr = prefs.getString(PREFS_KEY_MESSAGE_HISTORY, null)
        if (!jsonStr.isNullOrEmpty()) {
            try {
                val array = JSONArray(JSONTokener(jsonStr))
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

        val prefs = SleepDetectionService.getPrefs(this)
        val currentHistory = getMessageHistory().toMutableList()
        currentHistory.remove(trimmed)
        currentHistory.add(0, trimmed)
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
        val prefs = SleepDetectionService.getPrefs(this)
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

    private fun syncConfigFromMac(explicit: Boolean = false) {
        lifecycleScope.launch {
            val res = syncClient.fetchConfig()
            if (res.isSuccess) {
                val config = res.getOrThrow()
                SleepDetectionService.saveSleepConfig(this@MainActivity, config)
                refreshStatus()
                if (authManager.currentUser != null) {
                    deviceSyncManager.savePreferencesToCloud(config)
                }
                if (explicit) {
                    Toast.makeText(this@MainActivity, "Preferences synced from Mac!", Toast.LENGTH_SHORT).show()
                }
            } else if (explicit) {
                Toast.makeText(this@MainActivity, "Failed to sync config from Mac: ${res.exceptionOrNull()?.message}", Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun startSleepService() {
        if (SleepDetectionService.shouldRunService(this)) {
            val intent = Intent(this, SleepDetectionService::class.java).apply {
                action = SleepDetectionService.ACTION_START_SERVICE
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } else {
            SleepDetectionService.scheduleNextWindowTransitionAlarm(this)
        }
    }

    private fun refreshStatus() {
        isProgrammaticUpdate = true
        try {
            val timeoutMs = InactivityCompensator.getSystemScreenTimeoutMs(this)
            val timeoutMinutes = timeoutMs / 60_000L
            tvDisplayTimeout.text = "Live Display Sleep Timeout: $timeoutMinutes minutes"

            val config = SleepDetectionService.getSleepConfig(this)
            tvSleepDuration.text = "Target Duration: ${config.defaultSleepHours} hours"
            tvSleepWindow.text = "Eligible Sleep Window: ${formatHour(config.sleepWindowStartHour)} – ${formatHour(config.sleepWindowEndHour)}"
            tvAutoPushWindow.text = "Auto-Push Window: ${formatHour(config.autoPushWindowStartHour)} – ${formatHour(config.autoPushWindowEndHour)}"

            // Update Tab 1 duration chips and button text
            selectedSleepDuration = config.defaultSleepHours
            btnManualSleep.text = "🌙 Start Sleep Session (${selectedSleepDuration}h)"
            val chipIdToCheck = when (config.defaultSleepHours) {
                6.0 -> R.id.chipDuration6
                7.0 -> R.id.chipDuration7
                7.5 -> R.id.chipDuration75
                8.0 -> R.id.chipDuration8
                9.0 -> R.id.chipDuration9
                else -> View.NO_ID
            }
            if (chipIdToCheck != View.NO_ID) {
                chipGroupSleepDuration.check(chipIdToCheck)
            } else {
                chipGroupSleepDuration.clearCheck()
            }

            // Update settings inputs if not being focused
            if (!etSettingSleepHours.hasFocus()) {
                etSettingSleepHours.setText(String.format(Locale.US, "%.1f", config.defaultSleepHours))
            }
            spSleepStartHour.setSelection(config.sleepWindowStartHour.coerceIn(0, 23))
            spSleepEndHour.setSelection(config.sleepWindowEndHour.coerceIn(0, 23))
            spAutoPushStartHour.setSelection(config.autoPushWindowStartHour.coerceIn(0, 23))
            spAutoPushEndHour.setSelection(config.autoPushWindowEndHour.coerceIn(0, 23))

            switchAutoDetectInactivity.isChecked = config.autoDetectInactivity
            layoutCustomOffset.visibility = if (config.autoDetectInactivity) View.GONE else View.VISIBLE
            if (!etInactivityOffset.hasFocus()) {
                etInactivityOffset.setText(config.inactivityOffsetMinutes.toInt().toString())
            }

            if (!etNightColorHex.hasFocus()) etNightColorHex.setText(config.ambientNightColorHex)
            if (!etDawnColorHex.hasFocus()) etDawnColorHex.setText(config.ambientDawnColorHex)
            if (!etWakeColorHex.hasFocus()) etWakeColorHex.setText(config.ambientWakeColorHex)

            updateColorPreview(viewNightColorPreview, config.ambientNightColorHex, Color.parseColor("#D95926"))
            updateColorPreview(viewDawnColorPreview, config.ambientDawnColorHex, Color.parseColor("#FA7268"))
            updateColorPreview(viewWakeColorPreview, config.ambientWakeColorHex, Color.parseColor("#FFD000"))

            isUpdatingAwaySwitch = true
            switchAwayMode.isChecked = config.isAwayMode
            isUpdatingAwaySwitch = false

            val targetMs = SleepDetectionService.getActiveTargetWakeMs(this)
            val now = System.currentTimeMillis()
            if (config.isAwayMode) {
                tvSleepStatus.text = "Status: Away Mode (Paused)"
                tvWakeTarget.text = "Target: Standby"
            } else if (targetMs != null && now < targetMs) {
                val timeFormat = SimpleDateFormat("h:mm a", Locale.getDefault())
                tvSleepStatus.text = "Status: Sleeping"
                tvWakeTarget.text = "Target Wake Up: ${timeFormat.format(Date(targetMs))} (${config.defaultSleepHours}h)"
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

            val tvChecklistHeader = findViewById<TextView?>(R.id.tvChecklistHeader)
            if (tvChecklistHeader != null) {
                val brand = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
                tvChecklistHeader.text = if (OEMPowerHelper.isAggressiveOEM()) {
                    "$brand Background Protection Checklist"
                } else {
                    "Background Protection Checklist"
                }
            }

            val btnBatteryOpt = findViewById<Button>(R.id.btnBatteryOpt)
            val btnUsageAccess = findViewById<Button>(R.id.btnUsageAccess)
            val btnAutoLaunch = findViewById<Button>(R.id.btnAutoLaunch)

            if (OEMPowerHelper.isIgnoringBatteryOptimizations(this)) {
                btnBatteryOpt.text = "✅ 1. Battery Optimization: Unrestricted"
            } else {
                btnBatteryOpt.text = "⚠️ 1. Disable Battery Optimization (Action Required)"
            }
            if (OEMPowerHelper.hasUsageStatsPermission(this)) {
                btnUsageAccess.text = "✅ 2. Usage Access: Granted"
            } else {
                btnUsageAccess.text = "2. Grant Usage Access (Inactivity Check)"
            }

            if (!OEMPowerHelper.isAggressiveOEM()) {
                btnAutoLaunch.visibility = View.GONE
            } else {
                btnAutoLaunch.visibility = View.VISIBLE
                btnAutoLaunch.text = OEMPowerHelper.getChecklistButtonLabel()
            }
        } finally {
            isProgrammaticUpdate = false
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

    private fun updateCloudAuthUI() {
        val user = authManager.currentUser
        if (user != null) {
            tvCloudAuthStatus.text = "Signed in as: ${user.email ?: user.displayName}"
            tvCloudAuthStatus.setTextColor(Color.parseColor("#30D158"))
            btnGoogleSignIn.visibility = View.GONE
            btnSignOut.visibility = View.VISIBLE
            layoutFleetHeader.visibility = View.VISIBLE
            tvHeaderSyncIndicator.text = "CLOUD SYNC"
            tvHeaderSyncIndicator.setTextColor(Color.parseColor("#30D158"))

            deviceSyncManager.registerCurrentDevice()
            deviceSyncManager.startListeningToPreferences { cloudConfig ->
                val localConfig = SleepDetectionService.getSleepConfig(this@MainActivity)
                if (cloudConfig != localConfig) {
                    SleepDetectionService.saveSleepConfig(this@MainActivity, cloudConfig)
                    refreshStatus()
                }
            }
            deviceSyncManager.startListeningToDevices { devices ->
                cloudDevices = devices.filter { it.deviceType in listOf("machine", "macos") }
                if (selectedFleetDeviceIds.isEmpty() && cbSelectAllFleet.isChecked) {
                    selectedFleetDeviceIds.addAll(cloudDevices.map { it.deviceId })
                } else {
                    val validIds = cloudDevices.map { it.deviceId }.toSet()
                    selectedFleetDeviceIds.retainAll(validIds)
                }
                renderFleetDeviceList()
            }
        } else {
            deviceSyncManager.stopListeningToPreferences()
            tvCloudAuthStatus.text = "Sign in with Google to sync devices anywhere"
            tvCloudAuthStatus.setTextColor(Color.parseColor("#8E8E93"))
            btnGoogleSignIn.visibility = View.VISIBLE
            btnSignOut.visibility = View.GONE
            layoutFleetHeader.visibility = View.GONE
            layoutFleetDeviceList.removeAllViews()
            tvFleetEmptyState.visibility = View.VISIBLE
            tvFleetEmptyState.text = "Sign in with Google to discover and target workstation fleet machines."
            tvHeaderSyncIndicator.text = "LOCAL ONLY"
            tvHeaderSyncIndicator.setTextColor(Color.parseColor("#8E8E93"))
            cloudDevices = emptyList()
            selectedFleetDeviceIds.clear()
        }
    }

    private fun renderFleetDeviceList() {
        val total = cloudDevices.size
        val selectedCount = selectedFleetDeviceIds.size
        tvCloudDevicesHeader.text = "Workstation Fleet Targets ($total machines):"

        cbSelectAllFleet.setOnCheckedChangeListener(null)
        cbSelectAllFleet.isChecked = total > 0 && selectedCount == total
        cbSelectAllFleet.setOnCheckedChangeListener { _, isChecked ->
            if (isChecked) {
                selectedFleetDeviceIds.clear()
                selectedFleetDeviceIds.addAll(cloudDevices.map { it.deviceId })
            } else {
                selectedFleetDeviceIds.clear()
            }
            renderFleetDeviceList()
        }

        layoutFleetDeviceList.removeAllViews()
        if (cloudDevices.isEmpty()) {
            tvFleetEmptyState.visibility = View.VISIBLE
            tvFleetEmptyState.text = "No workstation machines registered yet. Ensure Ambient Display is running on your Mac."
            return
        }

        tvFleetEmptyState.visibility = View.GONE
        val inflater = LayoutInflater.from(this)

        for (device in cloudDevices) {
            val itemView = inflater.inflate(R.layout.item_fleet_device, layoutFleetDeviceList, false)
            val cbDeviceSelected = itemView.findViewById<CheckBox>(R.id.cbDeviceSelected)
            val tvDeviceName = itemView.findViewById<TextView>(R.id.tvDeviceName)
            val tvDeviceStatusPill = itemView.findViewById<TextView>(R.id.tvDeviceStatusPill)
            val tvDeviceDetails = itemView.findViewById<TextView>(R.id.tvDeviceDetails)
            val btnQuickClearDevice = itemView.findViewById<Button>(R.id.btnQuickClearDevice)

            tvDeviceName.text = device.deviceName
            val isOnline = device.isOnline
            if (isOnline) {
                tvDeviceStatusPill.text = "ONLINE"
                tvDeviceStatusPill.setBackgroundResource(R.drawable.bg_status_pill_online)
                tvDeviceStatusPill.setTextColor(Color.parseColor("#30D158"))
            } else {
                tvDeviceStatusPill.text = "OFFLINE"
                tvDeviceStatusPill.setBackgroundResource(R.drawable.bg_status_pill_offline)
                tvDeviceStatusPill.setTextColor(Color.parseColor("#8E8E93"))
            }

            val activeMsg = if (!device.activeCanvasTitle.isNullOrEmpty()) {
                "Active: \"${device.activeCanvasTitle}\""
            } else {
                "Active: Idle"
            }
            tvDeviceDetails.text = "${device.deviceId} • $activeMsg"

            cbDeviceSelected.isChecked = selectedFleetDeviceIds.contains(device.deviceId)
            cbDeviceSelected.setOnCheckedChangeListener { _, isChecked ->
                if (isChecked) {
                    selectedFleetDeviceIds.add(device.deviceId)
                } else {
                    selectedFleetDeviceIds.remove(device.deviceId)
                }
                cbSelectAllFleet.setOnCheckedChangeListener(null)
                cbSelectAllFleet.isChecked = selectedFleetDeviceIds.size == cloudDevices.size && cloudDevices.isNotEmpty()
                cbSelectAllFleet.setOnCheckedChangeListener { _, allChecked ->
                    if (allChecked) {
                        selectedFleetDeviceIds.clear()
                        selectedFleetDeviceIds.addAll(cloudDevices.map { it.deviceId })
                    } else {
                        selectedFleetDeviceIds.clear()
                    }
                    renderFleetDeviceList()
                }
            }

            btnQuickClearDevice.setOnClickListener {
                lifecycleScope.launch {
                    val success = deviceSyncManager.clearCanvasOnDevices(listOf(device.deviceId))
                    if (success) {
                        Toast.makeText(this@MainActivity, "Cleared ${device.deviceName}", Toast.LENGTH_SHORT).show()
                    } else {
                        Toast.makeText(this@MainActivity, "Failed to clear ${device.deviceName}", Toast.LENGTH_SHORT).show()
                    }
                }
            }

            layoutFleetDeviceList.addView(itemView)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        deviceSyncManager.stopListening()
    }
}
