package com.german.health_anki_flutter

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

internal object RecallReminderDeliveryEligibility {
    fun canAttemptDelivery(readiness: RecallNotificationReadiness): Boolean =
        readiness == RecallNotificationReadiness.READY

    fun canDeliver(wasActive: Boolean, recordCommitted: Boolean): Boolean =
        wasActive && recordCommitted
}

object RecallReminderScheduler {
    private const val preferencesName = "recall_reminder"
    private const val activeKey = "active"
    private const val hourKey = "hour"
    private const val minuteKey = "minute"
    private const val triggerAtKey = "trigger_at_ms"
    private const val suppressedDayKey = "suppressed_study_day_ms"
    private const val requestCode = 5103

    fun apply(
        context: Context,
        settings: RecallReminderSettings,
        nowMillis: Long = System.currentTimeMillis(),
    ) {
        // A positive last-known workload permits future neutral nudges. Never
        // persist/repeat a count, infer work from unknown data, or fetch cards here.
        if (!settings.enabled || (settings.dueCount ?: 0) <= 0) {
            cancel(context)
            return
        }
        cancelAlarm(context)
        val prefs = preferences(context)
        val pendingTriggerAt = if (prefs.getBoolean(activeKey, false)) {
            prefs.getLong(triggerAtKey, 0L).takeIf { it > 0L }
        } else {
            null
        }
        val edit = prefs.edit()
            .putBoolean(activeKey, true)
            .putInt(hourKey, settings.hour)
            .putInt(minuteKey, settings.minute)
        if (settings.studiedToday) {
            RecallReminderNotifications.dismiss(context)
            edit.putLong(
                suppressedDayKey,
                maxOf(suppressedDay(context), RecallReminderTime.studyDay(nowMillis)),
            )
        }
        check(edit.commit()) { "Reminder eligibility was not saved" }
        schedule(context, settings.hour, settings.minute, nowMillis, pendingTriggerAt)
    }

    fun cancel(context: Context) {
        RecallReminderNotifications.dismiss(context)
        cancelAlarm(context)
        // Keep only the daily suppression marker: toggling off/on, signing out
        // or a zero-work refresh must not permit a second nudge on the same day.
        val day = suppressedDay(context)
        check(preferences(context).edit().clear().putLong(suppressedDayKey, day).commit()) {
            "Reminder cancellation was not saved"
        }
    }

    fun restore(context: Context, nowMillis: Long = System.currentTimeMillis()) {
        val prefs = preferences(context)
        if (!prefs.getBoolean(activeKey, false)) return
        schedule(
            context,
            prefs.getInt(hourKey, 19).coerceIn(0, 23),
            prefs.getInt(minuteKey, 0).coerceIn(0, 59),
            nowMillis,
        )
    }

    fun consume(context: Context, nowMillis: Long = System.currentTimeMillis()): Boolean {
        val prefs = preferences(context)
        val wasActive = prefs.getBoolean(activeKey, false)
        val triggerAt = prefs.getLong(triggerAtKey, 0L)
        val day = RecallReminderTime.studyDay(nowMillis)
        if (!wasActive || triggerAt <= 0L || triggerAt > nowMillis ||
            RecallReminderTime.studyDay(triggerAt) != day || suppressedDay(context) >= day
        ) return false
        // Record the day BEFORE posting. If persistence fails, fail closed.
        // Keep the recurrence and time so native delivery can rearm without Dart.
        val recordCommitted = prefs.edit().putLong(suppressedDayKey, day).commit()
        return RecallReminderDeliveryEligibility.canDeliver(wasActive, recordCommitted)
    }

    private fun suppressedDay(context: Context): Long =
        preferences(context).getLong(suppressedDayKey, Long.MIN_VALUE)

    private fun schedule(
        context: Context,
        hour: Int,
        minute: Int,
        nowMillis: Long,
        pendingTriggerAtMillis: Long? = null,
    ) {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val triggerAt = RecallReminderTime.nextTriggerAtMillis(
            hour = hour,
            minute = minute,
            nowMillis = nowMillis,
            pendingTriggerAtMillis = pendingTriggerAtMillis,
            suppressedThroughStudyDay = suppressedDay(context),
        )
        check(preferences(context).edit().putLong(triggerAtKey, triggerAt).commit()) {
            "Reminder time was not saved"
        }
        // Inexact by design: no exact-alarm permission/access is needed.
        manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent(context))
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
