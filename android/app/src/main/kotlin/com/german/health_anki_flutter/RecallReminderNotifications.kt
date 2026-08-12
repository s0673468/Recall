package com.german.health_anki_flutter

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings

internal enum class RecallNotificationReadiness {
    NEEDS_RUNTIME_PERMISSION,
    BLOCKED,
    READY;

    companion object {
        fun evaluate(
            sdkInt: Int,
            runtimePermissionGranted: Boolean,
            appNotificationsEnabled: Boolean,
            channelImportance: Int?,
        ): RecallNotificationReadiness {
            if (sdkInt >= Build.VERSION_CODES.TIRAMISU && !runtimePermissionGranted) {
                return NEEDS_RUNTIME_PERMISSION
            }
            if (!appNotificationsEnabled) return BLOCKED
            if (sdkInt >= Build.VERSION_CODES.O &&
                channelImportance == NotificationManager.IMPORTANCE_NONE
            ) {
                return BLOCKED
            }
            return READY
        }
    }
}

internal object RecallReminderNotifications {
    const val channelId = "recall_study_reminders"

    fun ensureChannel(context: Context): NotificationManager {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    context.getString(R.string.reminder_channel_name),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = context.getString(R.string.reminder_channel_description)
                },
            )
        }
        return manager
    }

    fun readiness(context: Context): RecallNotificationReadiness {
        val manager = ensureChannel(context)
        val permissionGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        val importance = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.getNotificationChannel(channelId)?.importance
        } else {
            null
        }
        return RecallNotificationReadiness.evaluate(
            sdkInt = Build.VERSION.SDK_INT,
            runtimePermissionGranted = permissionGranted,
            appNotificationsEnabled = manager.areNotificationsEnabled(),
            channelImportance = importance,
        )
    }

    fun settingsIntent(context: Context): Intent =
        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
}
