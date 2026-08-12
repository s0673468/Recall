package com.german.health_anki_flutter

import java.util.Calendar
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecallContractsTest {
    @Test
    fun validatedNetworkTransitionRetriggersAfterValidationIsLost() {
        val state = ValidatedNetworkTransition<String>()

        assertTrue(state.onCapabilitiesChanged("wifi", isValidated = true))
        assertFalse(state.onCapabilitiesChanged("wifi", isValidated = true))
        assertFalse(state.onCapabilitiesChanged("wifi", isValidated = false))
        assertTrue(state.onCapabilitiesChanged("wifi", isValidated = true))
        assertFalse(state.onLost("cellular"))
        assertTrue(state.onLost("wifi"))
    }

    @Test
    fun notificationReadinessCoversRuntimeGlobalAndChannelBlocks() {
        assertEquals(
            RecallNotificationReadiness.NEEDS_RUNTIME_PERMISSION,
            RecallNotificationReadiness.evaluate(
                sdkInt = 33,
                runtimePermissionGranted = false,
                appNotificationsEnabled = false,
                channelImportance = 0,
            ),
        )
        assertEquals(
            RecallNotificationReadiness.BLOCKED,
            RecallNotificationReadiness.evaluate(
                sdkInt = 32,
                runtimePermissionGranted = true,
                appNotificationsEnabled = false,
                channelImportance = null,
            ),
        )
        assertEquals(
            RecallNotificationReadiness.BLOCKED,
            RecallNotificationReadiness.evaluate(
                sdkInt = 33,
                runtimePermissionGranted = true,
                appNotificationsEnabled = true,
                channelImportance = 0,
            ),
        )
        assertEquals(
            RecallNotificationReadiness.READY,
            RecallNotificationReadiness.evaluate(
                sdkInt = 33,
                runtimePermissionGranted = true,
                appNotificationsEnabled = true,
                channelImportance = 3,
            ),
        )
    }

    @Test
    fun notificationSettingsUsesChannelPageOnlyWhereSupported() {
        assertEquals(
            RecallNotificationSettingsTarget.APPLICATION_DETAILS,
            RecallReminderNotifications.settingsTarget(sdkInt = 24),
        )
        assertEquals(
            RecallNotificationSettingsTarget.APPLICATION_DETAILS,
            RecallReminderNotifications.settingsTarget(sdkInt = 25),
        )
        assertEquals(
            RecallNotificationSettingsTarget.APP_NOTIFICATIONS,
            RecallReminderNotifications.settingsTarget(sdkInt = 26),
        )
        assertEquals(
            RecallNotificationSettingsTarget.APP_NOTIFICATIONS,
            RecallReminderNotifications.settingsTarget(sdkInt = 37),
        )
    }

    @Test
    fun reminderContractAcceptsOnlyCompleteBoundedValues() {
        val valid = mapOf(
            "enabled" to true,
            "hour" to 19,
            "minute" to 30,
            "dueCount" to 4,
            "studiedToday" to false,
        )

        assertNotNull(RecallContracts.reminderSettings(valid))
        assertNull(RecallContracts.reminderSettings(valid + ("card_id" to 9)))
        assertNull(RecallContracts.reminderSettings(valid + ("hour" to 24)))
        assertNull(RecallContracts.reminderSettings(valid + ("dueCount" to -1)))
    }

    @Test
    fun reminderDeliveryFailsClosedUnlessEligibilityClearIsDurable() {
        assertTrue(
            RecallReminderDeliveryEligibility.canDeliver(
                wasActive = true,
                clearCommitted = true,
            ),
        )
        assertFalse(
            RecallReminderDeliveryEligibility.canDeliver(
                wasActive = true,
                clearCommitted = false,
            ),
        )
        assertFalse(
            RecallReminderDeliveryEligibility.canDeliver(
                wasActive = false,
                clearCommitted = true,
            ),
        )
        assertTrue(
            RecallReminderDeliveryEligibility.canAttemptDelivery(
                RecallNotificationReadiness.READY,
            ),
        )
        assertFalse(
            RecallReminderDeliveryEligibility.canAttemptDelivery(
                RecallNotificationReadiness.NEEDS_RUNTIME_PERMISSION,
            ),
        )
        assertFalse(
            RecallReminderDeliveryEligibility.canAttemptDelivery(
                RecallNotificationReadiness.BLOCKED,
            ),
        )
    }

    @Test
    fun widgetContractRejectsExtraOrInvalidFields() {
        val valid = mapOf("dueCount" to 7, "updatedAtEpochMs" to 1_786_000_000_000L)

        assertNotNull(RecallContracts.widgetSnapshot(valid))
        assertNull(RecallContracts.widgetSnapshot(valid + ("user_id" to "private")))
        assertNull(RecallContracts.widgetSnapshot(valid + ("dueCount" to -1)))
        assertNull(RecallContracts.widgetSnapshot(valid + ("updatedAtEpochMs" to 0)))
    }

    @Test
    fun nextReminderUsesTodayBeforeTimeAndTomorrowAfterTime() {
        val zone = TimeZone.getTimeZone("America/Sao_Paulo")
        fun at(hour: Int, minute: Int) = Calendar.getInstance(zone).apply {
            set(2026, Calendar.AUGUST, 11, hour, minute, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis

        assertEquals(
            at(19, 0),
            RecallReminderTime.nextTriggerAtMillis(19, 0, at(18, 0), zone),
        )
        assertEquals(
            at(19, 0) + 24 * 60 * 60 * 1000,
            RecallReminderTime.nextTriggerAtMillis(19, 0, at(20, 0), zone),
        )
    }

    @Test
    fun widgetBecomesStaleAtItsSingleRefreshDeadline() {
        val updatedAt = 1_786_000_000_000L

        assertEquals(
            updatedAt + RecallWidgetFreshness.staleAfterMs,
            RecallWidgetFreshness.staleDeadline(updatedAt),
        )
        assertFalse(
            RecallWidgetFreshness.isStale(
                hasSnapshot = true,
                updatedAtEpochMs = updatedAt,
                nowEpochMs = updatedAt + RecallWidgetFreshness.staleAfterMs - 1,
            ),
        )
        assertTrue(
            RecallWidgetFreshness.isStale(
                hasSnapshot = true,
                updatedAtEpochMs = updatedAt,
                nowEpochMs = updatedAt + RecallWidgetFreshness.staleAfterMs,
            ),
        )
        assertTrue(
            RecallWidgetFreshness.isStale(
                hasSnapshot = false,
                updatedAtEpochMs = updatedAt,
                nowEpochMs = updatedAt,
            ),
        )
    }

    @Test
    fun diagnosticsRejectInvalidCalendarDates() {
        assertTrue(
            RecallOperationalDiagnostics.isTimestamp("2026-08-11T12:00:00.000Z"),
        )
        assertFalse(
            RecallOperationalDiagnostics.isTimestamp("2026-99-99T12:00:00.000Z"),
        )
    }
}
