package com.german.health_anki_flutter

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build

class RecallReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        onReceiveAt(context, System.currentTimeMillis())
    }

    internal fun onReceiveAt(context: Context, nowMillis: Long) {
        deliver(context, nowMillis, RecallReminderNotifications.readiness(context)) {
            postNotification(context)
        }
    }

    internal fun deliver(
        context: Context,
        nowMillis: Long,
        readiness: RecallNotificationReadiness,
        post: () -> Unit,
    ) {
        val deliver = RecallReminderDeliveryEligibility.canAttemptDelivery(readiness) &&
            RecallReminderScheduler.consume(context, nowMillis)
        // Every one-shot attempt arms the next slot, including ignored nudges
        // and blocked permission/channel settings. No Flutter engine is needed.
        RecallReminderScheduler.restore(context, nowMillis)
        if (!deliver) return
        try {
            post()
        } catch (_: SecurityException) {
            // Permission can be revoked between the readiness check and notify.
            // Tomorrow is already armed; never crash or retry twice today.
        }
    }

    private fun postNotification(context: Context) {
        val manager = RecallReminderNotifications.ensureChannel(context)
        val openStudy = Intent(Intent.ACTION_VIEW, Uri.parse(RecallContracts.studyUri), context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val contentIntent = PendingIntent.getActivity(
            context,
            notificationRequestCode,
            openStudy,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, RecallReminderNotifications.channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(R.drawable.ic_study)
            .setContentTitle(context.getString(R.string.reminder_title))
            .setContentText(context.getString(R.string.reminder_body))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .build()
        manager.notify(RecallReminderNotifications.notificationId, notification)
    }

    private companion object {
        const val notificationRequestCode = 5105
    }
}

class RecallReminderRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        RecallReminderScheduler.restore(context)
    }
}
