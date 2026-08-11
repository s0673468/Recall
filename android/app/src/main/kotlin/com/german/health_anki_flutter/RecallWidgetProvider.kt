package com.german.health_anki_flutter

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews

class RecallWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { update(context, appWidgetManager, it) }
    }

    companion object {
        private const val preferencesName = "recall_widget"
        private const val dueCountKey = "due_count"
        private const val updatedAtKey = "updated_at"
        private const val staleAfterMs = 12L * 60 * 60 * 1000
        private const val openRequestCode = 5106

        fun store(context: Context, snapshot: RecallWidgetSnapshot) {
            context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
                .edit()
                .putInt(dueCountKey, snapshot.dueCount)
                .putLong(updatedAtKey, snapshot.updatedAtEpochMs)
                .apply()
            updateAll(context)
        }

        fun clear(context: Context) {
            context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
                .edit()
                .clear()
                .apply()
            updateAll(context)
        }

        private fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, RecallWidgetProvider::class.java),
            )
            ids.forEach { update(context, manager, it) }
        }

        private fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val prefs = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            val hasSnapshot = prefs.contains(dueCountKey) && prefs.contains(updatedAtKey)
            val dueCount = prefs.getInt(dueCountKey, 0).coerceAtLeast(0)
            val updatedAt = prefs.getLong(updatedAtKey, 0)
            val stale = !hasSnapshot ||
                updatedAt <= 0 ||
                System.currentTimeMillis() - updatedAt > staleAfterMs
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
