package com.ambientdisplay.util

import android.app.AppOpsManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.provider.Settings

object OEMPowerHelper {

    enum class OEMType {
        XIAOMI,
        SAMSUNG,
        OPPO_ONEPLUS,
        HUAWEI,
        VIVO,
        STOCK
    }

    fun getOEMType(): OEMType {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val brand = Build.BRAND.lowercase()

        return when {
            manufacturer.contains("xiaomi") || manufacturer.contains("redmi") || manufacturer.contains("poco") ||
            brand.contains("xiaomi") || brand.contains("redmi") || brand.contains("poco") -> OEMType.XIAOMI

            manufacturer.contains("samsung") || brand.contains("samsung") -> OEMType.SAMSUNG

            manufacturer.contains("oneplus") || manufacturer.contains("oppo") || manufacturer.contains("realme") ||
            brand.contains("oneplus") || brand.contains("oppo") || brand.contains("realme") -> OEMType.OPPO_ONEPLUS

            manufacturer.contains("huawei") || manufacturer.contains("honor") ||
            brand.contains("huawei") || brand.contains("honor") -> OEMType.HUAWEI

            manufacturer.contains("vivo") || manufacturer.contains("iqoo") ||
            brand.contains("vivo") || brand.contains("iqoo") -> OEMType.VIVO

            else -> OEMType.STOCK
        }
    }

    fun isAggressiveOEM(): Boolean = getOEMType() != OEMType.STOCK

    fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(context.packageName)
    }

    fun requestIgnoreBatteryOptimizations(context: Context) {
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:${context.packageName}")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            context.startActivity(intent)
        } catch (_: Exception) {
            val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            try {
                context.startActivity(fallback)
            } catch (_: Exception) {}
        }
    }

    fun hasUsageStatsPermission(context: Context): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName
            )
        } else {
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    fun openUsageStatsSettings(context: Context) {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            context.startActivity(intent)
        } catch (_: Exception) {}
    }

    fun openAccessibilitySettings(context: Context) {
        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            context.startActivity(intent)
        } catch (_: Exception) {}
    }

    fun getAutoLaunchTitle(): String {
        val formattedBrand = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
        return when (getOEMType()) {
            OEMType.XIAOMI -> "Xiaomi Autostart Required"
            OEMType.SAMSUNG -> "Samsung Background Limits"
            OEMType.OPPO_ONEPLUS -> "$formattedBrand Auto-Launch Settings"
            OEMType.HUAWEI -> "Huawei App Launch Settings"
            OEMType.VIVO -> "Vivo Background Power Settings"
            OEMType.STOCK -> "Background Activity Settings"
        }
    }

    fun getAutoLaunchMessage(): String {
        return when (getOEMType()) {
            OEMType.XIAOMI ->
                "MIUI / HyperOS aggressively restricts background processes.\n\n" +
                "Please enable 'Autostart' and set Battery Saver to 'No restrictions' so sleep detection and wake-up alarms fire reliably."

            OEMType.SAMSUNG ->
                "Samsung One UI may put background apps to sleep.\n\n" +
                "Please add Ambient Display to 'Never sleeping apps' in Battery settings so sleep tracking remains active."

            OEMType.OPPO_ONEPLUS ->
                "Your device may kill background services during deep sleep.\n\n" +
                "Please enable 'Auto-launch' and allow 'Background activity' in Battery settings so sleep tracking runs uninterrupted."

            OEMType.HUAWEI ->
                "Huawei EMUI manages startup automatically.\n\n" +
                "Please open App Launch settings, set Ambient Display to 'Manage manually', and allow 'Auto-launch' and 'Run in background'."

            OEMType.VIVO ->
                "Vivo Funtouch / OriginOS restricts background power.\n\n" +
                "Please allow 'High background power consumption' in Battery settings so the app is not suspended."

            OEMType.STOCK ->
                "To ensure background sleep tracking operates properly, please verify battery optimizations are unrestricted in App Info."
        }
    }

    fun getChecklistButtonLabel(): String {
        return when (getOEMType()) {
            OEMType.XIAOMI -> "4. Configure MIUI Autostart"
            OEMType.SAMSUNG -> "4. Configure Never Sleeping Apps"
            OEMType.OPPO_ONEPLUS -> "4. Configure Auto-Launch Manager"
            OEMType.HUAWEI -> "4. Configure App Launch"
            OEMType.VIVO -> "4. Configure Background Power"
            OEMType.STOCK -> "4. App Details / Background"
        }
    }

    /**
     * Opens manufacturer-specific auto-start or background management screens.
     */
    fun openAutoLaunchSettings(context: Context): Boolean {
        val intents = getOEMSpecificIntents(context)

        for (intent in intents) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                return true
            } catch (_: Exception) {
                // Try next candidate intent
            }
        }

        // Universal fallback: Open standard App Info page
        return try {
            val appDetails = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:${context.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(appDetails)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun getOEMSpecificIntents(context: Context): List<Intent> {
        return when (getOEMType()) {
            OEMType.XIAOMI -> listOf(
                Intent().setComponent(ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")),
                Intent().setComponent(ComponentName("com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity")),
                Intent("miui.intent.action.OP_AUTO_START").addCategory(Intent.CATEGORY_DEFAULT)
            )

            OEMType.SAMSUNG -> listOf(
                Intent().setComponent(ComponentName("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity")),
                Intent().setComponent(ComponentName("com.samsung.android.sm", "com.samsung.android.sm.battery.ui.BatteryActivity")),
                Intent().setComponent(ComponentName("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity")),
                Intent().setComponent(ComponentName("com.samsung.android.sm", "com.samsung.android.sm.ui.battery.BatteryActivity"))
            )

            OEMType.OPPO_ONEPLUS -> listOf(
                Intent().setComponent(ComponentName("com.oplus.battery", "com.oplus.battery.StartupAppActivity")),
                Intent().setComponent(ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity")),
                Intent().setComponent(ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity")),
                Intent().setComponent(ComponentName("com.oplus.safecenter", "com.oplus.safecenter.startupapp.StartupAppListActivity")),
                Intent().setComponent(ComponentName("com.coloros.oppoguardelf", "com.coloros.powermanager.fuelga设置ge.PowerConsumptionActivity"))
            )

            OEMType.HUAWEI -> listOf(
                Intent().setComponent(ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity")),
                Intent().setComponent(ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.bootstart.BootStartActivity")),
                Intent().setComponent(ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"))
            )

            OEMType.VIVO -> listOf(
                Intent().setComponent(ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity")),
                Intent().setComponent(ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager")),
                Intent().setComponent(ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"))
            )

            OEMType.STOCK -> emptyList()
        }
    }
}
