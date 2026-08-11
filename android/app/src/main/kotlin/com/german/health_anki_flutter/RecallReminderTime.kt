package com.german.health_anki_flutter

import java.util.Calendar
import java.util.TimeZone

object RecallReminderTime {
    fun nextTriggerAtMillis(
        hour: Int,
        minute: Int,
        nowMillis: Long,
        timeZone: TimeZone = TimeZone.getDefault(),
    ): Long {
        require(hour in 0..23 && minute in 0..59)
        val next = Calendar.getInstance(timeZone).apply {
            timeInMillis = nowMillis
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= nowMillis) add(Calendar.DAY_OF_YEAR, 1)
        }
        return next.timeInMillis
    }
}
