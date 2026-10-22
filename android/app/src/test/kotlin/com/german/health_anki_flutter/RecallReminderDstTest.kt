package com.german.health_anki_flutter

import java.time.Instant
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Test

class RecallReminderDstTest {
    private val zone = TimeZone.getTimeZone("America/New_York")

    @Test
    fun passedSpringGapDoesNotShiftTomorrowsReminder() {
        assertEquals(
            Instant.parse("2026-03-09T06:30:00Z").toEpochMilli(),
            RecallReminderTime.nextTriggerAtMillis(
                hour = 2,
                minute = 30,
                nowMillis = Instant.parse("2026-03-08T16:00:00Z").toEpochMilli(),
                timeZone = zone,
            ),
        )
    }

    @Test
    fun upcomingSpringGapStillUsesNormalizedLocalTime() {
        assertEquals(
            Instant.parse("2026-03-08T07:30:00Z").toEpochMilli(),
            RecallReminderTime.nextTriggerAtMillis(
                hour = 2,
                minute = 30,
                nowMillis = Instant.parse("2026-03-08T05:00:00Z").toEpochMilli(),
                timeZone = zone,
            ),
        )
    }

    @Test
    fun nextDayAcrossFallBackKeepsTheRequestedWallTime() {
        assertEquals(
            Instant.parse("2026-11-01T14:00:00Z").toEpochMilli(),
            RecallReminderTime.nextTriggerAtMillis(
                hour = 9,
                minute = 0,
                nowMillis = Instant.parse("2026-10-31T16:00:00Z").toEpochMilli(),
                timeZone = zone,
            ),
        )
    }
}
