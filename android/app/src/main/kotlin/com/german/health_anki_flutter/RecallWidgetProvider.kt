package com.german.health_anki_flutter

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews

internal object RecallWidgetFreshness {
    const val staleAfterMs = 12L * 60 * 60 * 1000

    fun staleDeadline(updatedAtEpochMs: Long): Long =
        if (updatedAtEpochMs > Long.MAX_VALUE - staleAfterMs) {
            Long.MAX_VALUE
        } else {
            updatedAtEpochMs + staleAfterMs
        }

    fun isStale(
        hasSnapshot: Boolean,
        updatedAtEpochMs: Long,
        nowEpochMs: Long,
    ): Boolean = !hasSnapshot ||
        updatedAtEpochMs <= 0 ||
        nowEpochMs >= staleDeadline(updatedAtEpochMs)
}

class RecallWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_REFRESH_STALE) {
            updateAll(context)
            return
        }
        super.onReceive(context, intent)
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { update(context, appWidgetManager, it) }
        scheduleStoredSnapshotRefresh(context)
    }

    override fun onDisabled(context: Context) {
        cancelStaleRefresh(context)
        super.onDisabled(context)
    }

    companion object {
        private const val preferencesName = "recall_widget"
        private const val dueCountKey = "due_count"
        private const val updatedAtKey = "updated_at"
        private const val openRequestCode = 5106
        private const val staleRefreshRequestCode = 5107
        private const val ACTION_REFRESH_STALE =
            "com.german.health_anki_flutter.action.REFRESH_WIDGET_STALE"

        fun store(context: Context, snapshot: RecallWidgetSnapshot) {
            context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
                .edit()
                .putInt(dueCountKey, snapshot.dueCount)
                .putLong(updatedAtKey, snapshot.updatedAtEpochMs)
                .apply()
            val hasWidgets = updateAll(context)
            if (hasWidgets) {
                scheduleStaleRefresh(context, snapshot.updatedAtEpochMs)
            } else {
                cancelStaleRefresh(context)
            }
        }

        fun clear(context: Context) {
            cancelStaleRefresh(context)
            context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
                .edit()
                .clear()
                .apply()
            updateAll(context)
        }

        private fun updateAll(context: Context): Boolean {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, RecallWidgetProvider::class.java),
            )
            ids.forEach { update(context, manager, it) }
            return ids.isNotEmpty()
        }

        private fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val prefs = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            val hasSnapshot = prefs.contains(dueCountKey) && prefs.contains(updatedAtKey)
            val dueCount = prefs.getInt(dueCountKey, 0).coerceAtLeast(0)
            val updatedAt = prefs.getLong(updatedAtKey, 0)
            val stale = RecallWidgetFreshness.isStale(
                hasSnapshot = hasSnapshot,
                updatedAtEpochMs = updatedAt,
                nowEpochMs = System.currentTimeMillis(),
            )
            val views = RemoteViews(context.packageName, R.layout.recall_widget).apply {
                setTextViewText(
                    R.id.recall_widget_count,
                    if (hasSnapshot) dueCount.toString() else context.getString(R.string.widget_open),
                )
                setTextViewText(
                    R.id.recall_widget_label,
                    if (!hasSnapshot) {
                        context.getString(R.string.widget_load_count)
                    } else if (dueCount == 1) {
                        context.getString(R.string.widget_card_due)
                    } else {
                        context.getString(R.string.widget_cards_due)
                    },
                )
                setTextViewText(
                    R.id.recall_widget_freshness,
                    if (stale) context.getString(R.string.widget_stale) else context.getString(R.string.widget_updated),
                )
                setOnClickPendingIntent(R.id.recall_widget_root, openStudyIntent(context))
                setOnClickPendingIntent(R.id.recall_widget_action, openStudyIntent(context))
            }
            manager.updateAppWidget(id, views)
        }

        private fun scheduleStoredSnapshotRefresh(context: Context) {
            val prefs = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            val updatedAt = prefs.getLong(updatedAtKey, 0)
            if (!prefs.contains(dueCountKey) || updatedAt <= 0) {
                cancelStaleRefresh(context)
                return
            }
            scheduleStaleRefresh(context, updatedAt)
        }

        private fun scheduleStaleRefresh(context: Context, updatedAtEpochMs: Long) {
            val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pendingIntent = staleRefreshIntent(context)
            manager.cancel(pendingIntent)
            val deadline = RecallWidgetFreshness.staleDeadline(updatedAtEpochMs)
            if (deadline <= System.currentTimeMillis()) return
            manager.set(
                AlarmManager.RTC,
                deadline,
                pendingIntent,
            )
        }

        private fun cancelStaleRefresh(context: Context) {
            val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            manager.cancel(staleRefreshIntent(context))
        }

        private fun staleRefreshIntent(context: Context): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                staleRefreshRequestCode,
                Intent(context, RecallWidgetProvider::class.java)
                    .setAction(ACTION_REFRESH_STALE),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        private fun openStudyIntent(context: Context): PendingIntent {
            val intent = Intent(
                Intent.ACTION_VIEW,
                Uri.parse(RecallContracts.studyUri),
                context,
                MainActivity::class.java,
            ).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return PendingIntent.getActivity(
                context,
                openRequestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }
}
