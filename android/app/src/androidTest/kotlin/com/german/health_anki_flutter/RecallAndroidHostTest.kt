package com.german.health_anki_flutter

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RecallAndroidHostTest {
    @Test
    fun diagnosticsMirrorAcceptsOnlyTheClosedValueFreeEnvelope() {
        val canonical = """[{"schema":"operational-event/v2","timestamp":"2026-08-11T12:00:00.000Z","level":"error","project":"recall","component":"auth","operation":"observe_auth_state","outcome":"failed","cause_code":"auth.stream_error","retryable":true,"run_id":"run-test"}]"""

        assertTrue(RecallOperationalDiagnostics.isCanonical(canonical))
        assertFalse(
            RecallOperationalDiagnostics.isCanonical(
                canonical.replace("\"run_id\"", "\"card_id\":42,\"run_id\""),
            ),
        )
        assertFalse(
            RecallOperationalDiagnostics.isCanonical(
                canonical.replace("2026-08-11", "2026-99-99"),
            ),
        )
    }

    @Test
    fun exactStudyDeepLinkResolvesInsideRecall() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(RecallContracts.studyUri))
            .setPackage(context.packageName)

        assertTrue(context.packageManager.queryIntentActivities(intent, 0).isNotEmpty())
    }

    @Test
    fun notificationSettingsRecoveryResolvesOnTheDevice() {
        val context = ApplicationProvider.getApplicationContext<Context>()

        assertNotNull(
            RecallReminderNotifications.settingsIntent(context)
                .resolveActivity(context.packageManager),
        )
    }

    @Test
    fun reminderReceiverPostsAnAggregateNotificationWhenAllowed() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val runtimePermissionGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        assumeTrue(runtimePermissionGranted)
        assumeTrue(manager.areNotificationsEnabled())

        try {
            val now = System.currentTimeMillis()
            RecallReminderScheduler.apply(
                context,
                RecallReminderSettings(
                    enabled = true,
                    hour = 19,
                    minute = 0,
                    dueCount = 1,
                    studiedToday = false,
                ),
                nowMillis = now,
            )
            val target = RecallReminderTime.nextTriggerAtMillis(19, 0, now)
            RecallReminderReceiver().onReceiveAt(context, target)

            val reminder = manager.activeNotifications.firstOrNull {
                it.notification.category == Notification.CATEGORY_REMINDER
            }
            assertNotNull(reminder)
            assertNotNull(reminder!!.notification.contentIntent)
            assertFalse(
                "A duplicate attempt must not deliver twice on one study day.",
                RecallReminderScheduler.consume(context, target),
            )
        } finally {
            RecallReminderScheduler.cancel(context)
            manager.cancelAll()
        }
    }

    @Test
    fun reminderReceiverPreservesEligibilityWhenDeliveryIsBlocked() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        assumeTrue(
            RecallReminderNotifications.readiness(context) !=
                RecallNotificationReadiness.READY,
        )

        try {
            val now = System.currentTimeMillis()
            RecallReminderScheduler.apply(
                context,
                RecallReminderSettings(
                    enabled = true,
                    hour = 19,
                    minute = 0,
                    dueCount = 1,
                    studiedToday = false,
                ),
                nowMillis = now,
            )

            val target = RecallReminderTime.nextTriggerAtMillis(19, 0, now)
            RecallReminderReceiver().onReceiveAt(context, target)

            assertTrue(
                "Blocked delivery must leave eligibility recoverable.",
                RecallReminderScheduler.consume(context, RecallReminderTime.nextTriggerAtMillis(19, 0, target)),
            )
        } finally {
            RecallReminderScheduler.cancel(context)
        }
    }
}
