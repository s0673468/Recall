package com.german.health_anki_flutter

import android.app.AlarmManager
import android.content.Context
import java.util.Calendar
import java.util.TimeZone
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAlarmManager

/** Synthetic clock, Android preferences and alarms. No account, device or backend. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class RecallReminderReconciliationTest {
    private lateinit var context: Context
    private lateinit var manager: AlarmManager
    private lateinit var originalZone: TimeZone
    private var nowMillis = 0L
    private val brt = TimeZone.getTimeZone("America/Sao_Paulo")
    private val settings = RecallReminderSettings(true, 19, 0, 3, false)

    @Before
    fun setUp() {
        originalZone = TimeZone.getDefault()
        TimeZone.setDefault(brt)
        context = RuntimeEnvironment.getApplication()
        manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        nowMillis = at(18, 0)
        ShadowAlarmManager.setCanScheduleExactAlarms(false)
    }

    @After
    fun tearDown() {
        RecallReminderScheduler.cancel(context)
        TimeZone.setDefault(originalZone)
    }

    @Test
    fun countRefreshDoesNotSkipAnInexactAlarmAwaitingDelivery() {
        apply(settings)
        assertEquals(at(19, 0), nextAlarm())

        // Inexact delivery can be delayed. A foreground/count reconciliation
        // after the requested time must keep today's still-pending reminder.
        nowMillis = at(19, 10)
        apply(settings.copy(dueCount = 4))

        assertEquals(at(19, 0), nextAlarm())
        assertEquals(1, shadowOf(manager).scheduledAlarms.size)
    }

    @Test
    fun changingTimeReplacesThePendingSlot() {
        apply(settings)
        nowMillis = at(19, 10)
        apply(settings.copy(hour = 20))

        assertEquals(at(20, 0), nextAlarm())
        assertEquals(1, shadowOf(manager).scheduledAlarms.size)
    }

    @Test
    fun consumedEligibilityDoesNotResurrectAnOverdueSlot() {
        apply(settings)
        assertEquals(true, RecallReminderScheduler.consume(context))
        assertFalse(RecallReminderScheduler.consume(context))
        nowMillis = at(19, 10)
        apply(settings)

        assertEquals(at(19, 0, day = 24), nextAlarm())
    }

    @Test
    fun restoreAfterRebootOrUpdateKeepsOneAlarmAtLocalTime() {
        apply(settings)
        val pending = requireNotNull(shadowOf(manager).peekNextScheduledAlarm())
        manager.cancel(requireNotNull(pending.operation))
        RecallReminderScheduler.restore(context, nowMillis)
        RecallReminderScheduler.restore(context, nowMillis)

        assertEquals(at(19, 0), nextAlarm())
        assertEquals(1, shadowOf(manager).scheduledAlarms.size)
    }

    @Test
    fun timezoneRestoreRecalculatesTheWallTime() {
        apply(settings)
        val newZone = TimeZone.getTimeZone("America/Manaus")
        TimeZone.setDefault(newZone)
        RecallReminderScheduler.restore(context, nowMillis)

        assertEquals(at(19, 0, zone = newZone), nextAlarm())
        assertEquals(1, shadowOf(manager).scheduledAlarms.size)
    }

    @Test
    fun aPreviousDaysPendingTargetCannotFireToday() {
        apply(settings)
        nowMillis = at(10, 0, day = 24)
        apply(settings)

        assertEquals(at(19, 0, day = 24), nextAlarm())
    }

    @Test
    fun newlyEnabledAfterTheChosenTimeSchedulesTomorrow() {
        nowMillis = at(19, 10)
        apply(settings)

        assertEquals(at(19, 0, day = 24), nextAlarm())
    }

    @Test
    fun disablingOrLosingDueWorkPreventsRestore() {
        for (ineligible in listOf(settings.copy(enabled = false), settings.copy(dueCount = 0))) {
            apply(settings)
            apply(ineligible)
            RecallReminderScheduler.restore(context, nowMillis)

            assertEquals(0, shadowOf(manager).scheduledAlarms.size)
            assertFalse(RecallReminderScheduler.consume(context))
        }
    }

    private fun apply(value: RecallReminderSettings) =
        RecallReminderScheduler.apply(context, value, nowMillis)

    private fun nextAlarm(): Long =
        requireNotNull(shadowOf(manager).peekNextScheduledAlarm()).triggerAtTime

    private fun at(hour: Int, minute: Int, day: Int = 23, zone: TimeZone = brt): Long =
        Calendar.getInstance(zone).apply {
            set(2026, Calendar.OCTOBER, day, hour, minute, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
}
