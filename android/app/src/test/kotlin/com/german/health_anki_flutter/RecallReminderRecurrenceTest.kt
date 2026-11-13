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

/** Real native preferences, alarm replacement and receiver dispatch; no Dart/app refresh. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class RecallReminderRecurrenceTest {
    private lateinit var context: Context
    private lateinit var alarms: AlarmManager
    private lateinit var originalZone: TimeZone
    private val settings = RecallReminderSettings(true, 19, 0, 3, false)
    private var deliveries = 0

    @Before
    fun setUp() {
        originalZone = TimeZone.getDefault()
        TimeZone.setDefault(TimeZone.getTimeZone("America/Sao_Paulo"))
        context = RuntimeEnvironment.getApplication()
        alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        context.getSharedPreferences("recall_reminder", Context.MODE_PRIVATE).edit().clear().commit()
        ShadowAlarmManager.setCanScheduleExactAlarms(false)
    }

    @After
    fun tearDown() {
        RecallReminderScheduler.cancel(context)
        TimeZone.setDefault(originalZone)
    }

    @Test
    fun ignoredNudgesContinueForSeveralDaysWithoutAnyDartApply() {
        RecallReminderScheduler.apply(context, settings, at(23, 18))
        for (day in 23..27) {
            assertEquals(at(day, 19), nextAlarm())
            fire(at(day, 19))
            assertEquals(day - 22, deliveries)
            assertEquals(at(day + 1, 19), nextAlarm())
            // Duplicate broadcast/process recreation cannot consume tomorrow.
            fire(at(day, 20))
            assertEquals(day - 22, deliveries)
        }
    }

    @Test
    fun studyingCancelsTodayAndKeepsTomorrowEvenIfNoAppOpensAgain() {
        RecallReminderScheduler.apply(context, settings, at(23, 10))
        RecallReminderScheduler.apply(context, settings.copy(studiedToday = true), at(23, 12))
        assertEquals(at(24, 19), nextAlarm())
        fire(at(23, 19))
        assertEquals(0, deliveries)
        fire(at(24, 19))
        assertEquals(1, deliveries)
        assertEquals(at(25, 19), nextAlarm())
    }

    @Test
    fun zeroUnknownOrDisabledWorkCannotDeliverOrRestore() {
        for (ineligible in listOf(
            settings.copy(dueCount = 0), settings.copy(dueCount = null), settings.copy(enabled = false),
        )) {
            RecallReminderScheduler.apply(context, settings, at(23, 10))
            RecallReminderScheduler.apply(context, ineligible, at(23, 12))
            fire(at(23, 19))
            RecallReminderScheduler.restore(context, at(24, 10))
            assertEquals(0, deliveries)
            assertEquals(0, shadowOf(alarms).scheduledAlarms.size)
        }
    }

    @Test
    fun rebootAndPackageUpdateRestoreAfterAnIgnoredDelivery() {
        RecallReminderScheduler.apply(context, settings, at(23, 10))
        fire(at(23, 19))
        alarms.cancel(requireNotNull(shadowOf(alarms).peekNextScheduledAlarm()!!.operation))
        // Both BOOT_COMPLETED and MY_PACKAGE_REPLACED use this restore path.
        RecallReminderScheduler.restore(context, at(24, 10))
        RecallReminderScheduler.restore(context, at(24, 10))
        assertEquals(at(24, 19), nextAlarm())
        fire(at(24, 19))
        assertEquals(2, deliveries)
    }

    @Test
    fun blockedNotificationsStaySilentAndCanRecoverOnAFollowingDay() {
        for (readiness in listOf(
            RecallNotificationReadiness.BLOCKED, RecallNotificationReadiness.NEEDS_RUNTIME_PERMISSION,
        )) {
            RecallReminderScheduler.apply(context, settings, at(23, 10))
            fire(at(23, 19), readiness)
            assertEquals(0, deliveries)
            assertEquals(at(24, 19), nextAlarm())
        }
        fire(at(24, 19))
        assertEquals(1, deliveries)
        assertEquals(at(25, 19), nextAlarm())
    }

    @Test
    fun permissionRevocationDuringPostDoesNotCrashOrLoseTomorrow() {
        RecallReminderScheduler.apply(context, settings, at(23, 10))
        RecallReminderReceiver().deliver(context, at(23, 19), RecallNotificationReadiness.READY) {
            throw SecurityException("synthetic permission revocation")
        }
        assertEquals(at(24, 19), nextAlarm())
        fire(at(23, 20))
        assertEquals(0, deliveries)
        fire(at(24, 19))
        assertEquals(1, deliveries)
    }

    @Test
    fun timeChangesAndDisableEnableCannotDeliverTwiceOnOneStudyDay() {
        RecallReminderScheduler.apply(context, settings, at(23, 10))
        fire(at(23, 19))
        RecallReminderScheduler.cancel(context)
        RecallReminderScheduler.apply(context, settings.copy(hour = 21), at(23, 20))
        assertEquals(at(24, 21), nextAlarm())
        fire(at(23, 21))
        assertEquals(1, deliveries)
        fire(at(24, 21))
        assertEquals(2, deliveries)
    }

    @Test
    fun changedTimeRejectsAnAlreadyQueuedOldAlarm() {
        RecallReminderScheduler.apply(context, settings, at(23, 10))
        RecallReminderScheduler.apply(context, settings.copy(hour = 20), at(23, 18))
        fire(at(23, 19))
        assertEquals(0, deliveries)
        assertEquals(at(23, 20), nextAlarm())
        fire(at(23, 20))
        assertEquals(1, deliveries)
    }

    @Test
    fun earlyOrPreviousDayAlarmCannotPost() {
        RecallReminderScheduler.apply(context, settings, at(23, 10))
        fire(at(23, 18))
        assertEquals(0, deliveries)
        // A delayed broadcast from yesterday must not become today's nudge.
        fire(at(24, 10))
        assertEquals(0, deliveries)
        assertEquals(at(24, 19), nextAlarm())
        fire(at(24, 19))
        assertEquals(1, deliveries)
    }

    @Test
    fun deviceZoneDoesNotChangeStudyDaySuppression() {
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
        // 00:00 UTC is still yesterday in BRT. Study then suppresses a 01:00 UTC nudge.
        RecallReminderScheduler.apply(context, settings.copy(hour = 1, studiedToday = true), at(23, 0))
        val target = nextAlarm()
        assertEquals(RecallReminderTime.studyDay(at(23, 0)) + 86400000L,
            RecallReminderTime.studyDay(target))
        assertFalse(RecallReminderScheduler.consume(context, at(23, 1)))
    }

    private fun fire(now: Long, readiness: RecallNotificationReadiness = RecallNotificationReadiness.READY) {
        RecallReminderReceiver().deliver(context, now, readiness) { deliveries++ }
    }

    private fun nextAlarm(): Long {
        assertEquals(1, shadowOf(alarms).scheduledAlarms.size)
        return requireNotNull(shadowOf(alarms).peekNextScheduledAlarm()).triggerAtTime
    }

    private fun at(day: Int, hour: Int): Long = Calendar.getInstance().apply {
        set(2026, Calendar.OCTOBER, day, hour, 0, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis
}
