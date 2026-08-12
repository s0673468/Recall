package com.german.health_anki_flutter

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

internal object RecallReminderDeliveryEligibility {
    fun canAttemptDelivery(readiness: RecallNotificationReadiness): Boolean =
        readiness == RecallNotificationReadiness.READY

    fun shouldReschedule(readiness: RecallNotificationReadiness): Boolean =
        !canAttemptDelivery(readiness)

    fun canDeliver(wasActive: Boolean, clearCommitted: Boolean): Boolean =
        wasActive && clearCommitted
}

object RecallReminderScheduler {
    private const val preferencesName = "recall_reminder"
    private const val activeKey = "active"
    private const val hourKey = "hour"
    private const val minuteKey = "minute"
    private const val requestCode = 5103

    fun apply(context: Context, settings: RecallReminderSettings) {
        cancelAlarm(context)
        val eligible = settings.enabled &&
            (settings.dueCount ?: 0) > 0 &&
            !settings.studiedToday
        if (!eligible) {
            preferences(context).edit().clear().apply()
            return
        }
        preferences(context).edit()
            .putBoolean(activeKey, true)
            .putInt(hourKey, settings.hour)
            .putInt(minuteKey, settings.minute)
            .apply()
        schedule(context, settings.hour, settings.minute)
    }

    fun cancel(context: Context) {
        cancelAlarm(context)
        preferences(context).edit().clear().apply()
    }

    fun restore(context: Context) {
        val prefs = preferences(context)
        if (!prefs.getBoolean(activeKey, false)) return
        schedule(
            context,
            prefs.getInt(hourKey, 19).coerceIn(0, 23),
            prefs.getInt(minuteKey, 0).coerceIn(0, 59),
        )
    }

    fun consume(context: Context): Boolean {
        val prefs = preferences(context)
        val wasActive = prefs.getBoolean(activeKey, false)
        if (!wasActive) return false
        val clearCommitted = prefs.edit().clear().commit()
        // Fail closed if the durable clear fails. Posting while the eligibility
        // remains active could restore and deliver the same reminder again.
        return RecallReminderDeliveryEligibility.canDeliver(
            wasActive = wasActive,
            clearCommitted = clearCommitted,
        )
    }

    private fun schedule(context: Context, hour: Int, minute: Int) {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val triggerAt = RecallReminderTime.nextTriggerAtMillis(
            hour = hour,
            minute = minute,
            nowMillis = System.currentTimeMillis(),
        )
        manager.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            triggerAt,
            pendingIntent(context),
        )
    }

    private fun cancelAlarm(context: Context) {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        manager.cancel(pendingIntent(context))
    }

    private fun pendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        requestCode,
        Intent(context, RecallReminderReceiver::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun preferences(context: Context) =
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
}
