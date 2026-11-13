package com.german.health_anki_flutter

import java.util.Calendar
import java.util.TimeZone

object RecallReminderTime {
    // Match Dart StudyDay: suppression and deduplication reset at midnight BRT,
    // even when the configured reminder wall time uses another device zone.
    fun studyDay(instantMillis: Long): Long =
        Calendar.getInstance(TimeZone.getTimeZone("America/Sao_Paulo")).apply {
            timeInMillis = instantMillis
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis

    fun nextTriggerAtMillis(
        hour: Int,
        minute: Int,
        nowMillis: Long,
        timeZone: TimeZone = TimeZone.getDefault(),
        pendingTriggerAtMillis: Long? = null,
        suppressedThroughStudyDay: Long = Long.MIN_VALUE,
    ): Long {
        require(hour in 0..23 && minute in 0..59)
        val next = Calendar.getInstance(timeZone).apply {
            timeInMillis = nowMillis
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            // Reconciliation must not skip an inexact alarm still awaiting
            // delivery today. Matching the computed wall-time target also
            // invalidates old targets after a time/date/zone setting change.
            if (timeInMillis <= nowMillis && timeInMillis != pendingTriggerAtMillis) {
                add(Calendar.DAY_OF_YEAR, 1)
                // Today's DST gap may have normalized the requested time.
                // Tomorrow must start from the user's wall time again.
                set(Calendar.HOUR_OF_DAY, hour)
                set(Calendar.MINUTE, minute)
            }
        }
        while (studyDay(next.timeInMillis) <= suppressedThroughStudyDay) {
            next.add(Calendar.DAY_OF_YEAR, 1)
            next.set(Calendar.HOUR_OF_DAY, hour)
            next.set(Calendar.MINUTE, minute)
        }
        return next.timeInMillis
    }
}
