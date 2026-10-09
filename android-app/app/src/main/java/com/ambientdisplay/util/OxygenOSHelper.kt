package com.ambientdisplay.util

import android.content.Context

/**
 * Backward compatibility facade delegating to the universal [OEMPowerHelper].
 */
object OxygenOSHelper {

    fun isIgnoringBatteryOptimizations(context: Context): Boolean =
        OEMPowerHelper.isIgnoringBatteryOptimizations(context)

    fun requestIgnoreBatteryOptimizations(context: Context) =
        OEMPowerHelper.requestIgnoreBatteryOptimizations(context)

    fun hasUsageStatsPermission(context: Context): Boolean =
        OEMPowerHelper.hasUsageStatsPermission(context)

    fun openUsageStatsSettings(context: Context) =
        OEMPowerHelper.openUsageStatsSettings(context)

    fun openAccessibilitySettings(context: Context) =
        OEMPowerHelper.openAccessibilitySettings(context)

    fun openOnePlusAutoLaunchSettings(context: Context): Boolean =
        OEMPowerHelper.openAutoLaunchSettings(context)
}
