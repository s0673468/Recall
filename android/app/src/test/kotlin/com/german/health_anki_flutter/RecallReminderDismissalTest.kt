package com.german.health_anki_flutter

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Posted synthetic notifications, isolated preferences and alarms; no device/account. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class RecallReminderDismissalTest {
    private lateinit var context: Context
    private lateinit var manager: NotificationManager
    private val settings = RecallReminderSettings(true, 19, 0, 3, false)
    private val now = 1792771200000L

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel(
            RecallReminderNotifications.channelId, "Synthetic reminder", NotificationManager.IMPORTANCE_DEFAULT,
        ))
    }

    @Test
    fun completingDueWorkWithdrawsPostedReminder() {
        postReminder()
        RecallReminderScheduler.apply(context, settings.copy(dueCount = 0), now)
        assertDismissed()
    }

    @Test
    fun disablingWithdrawsPostedReminder() {
        postReminder()
        RecallReminderScheduler.apply(context, settings.copy(enabled = false), now)
        assertDismissed()
    }

    @Test
    fun studiedTodayWithdrawsPostedReminder() {
        postReminder()
        RecallReminderScheduler.apply(context, settings.copy(studiedToday = true), now)
        assertDismissed()
    }

    @Test
    fun explicitCancellationIsIdempotentAfterDeliveryConsumedEligibility() {
        postReminder()
        RecallReminderScheduler.cancel(context)
        RecallReminderScheduler.cancel(context)
        assertDismissed()
    }

    @Test
    fun eligibleCountRefreshKeepsPostedReminder() {
        postReminder()
        RecallReminderScheduler.apply(context, settings.copy(dueCount = 2), now)
        assertNotNull(shadowOf(manager).getNotification(RecallReminderNotifications.notificationId))
    }

    private fun postReminder() {
        RecallReminderScheduler.apply(context, settings, now)
        // Delivery consumes eligibility before posting. Dismissal must work
        // even though active/pending preferences are already gone.
        assertEquals(true, RecallReminderScheduler.consume(context))
        val notification = Notification.Builder(context, RecallReminderNotifications.channelId)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Synthetic reminder")
            .build()
        manager.notify(RecallReminderNotifications.notificationId, notification)
        manager.notify(9999, notification)
        assertNotNull(shadowOf(manager).getNotification(RecallReminderNotifications.notificationId))
    }

    private fun assertDismissed() {
        assertNull(shadowOf(manager).getNotification(RecallReminderNotifications.notificationId))
        assertNotNull(shadowOf(manager).getNotification(9999))
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        assertEquals(0, shadowOf(alarms).scheduledAlarms.size)
        RecallReminderScheduler.restore(context, now)
        assertEquals(0, shadowOf(alarms).scheduledAlarms.size)
        assertFalse(RecallReminderScheduler.consume(context))
    }
}
