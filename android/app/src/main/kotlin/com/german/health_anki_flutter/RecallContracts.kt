package com.german.health_anki_flutter

data class RecallReminderSettings(
    val enabled: Boolean,
    val hour: Int,
    val minute: Int,
    val dueCount: Int?,
    val studiedToday: Boolean,
)

data class RecallWidgetSnapshot(val dueCount: Int, val updatedAtEpochMs: Long)

object RecallContracts {
    const val backgroundSyncChannel = "com.german.ankiReview/backgroundSync"
    const val studyReminderChannel = "com.german.ankiReview/studyReminder"
    const val widgetChannel = "com.german.ankiReview/widget"
    const val operationalDiagnosticsChannel =
        "com.german.ankiReview/operationalDiagnostics"
    const val studyUri = "recall://study"

    fun reminderSettings(arguments: Any?): RecallReminderSettings? {
        val values = arguments as? Map<*, *> ?: return null
        if (values.keys != setOf("enabled", "hour", "minute", "dueCount", "studiedToday")) {
            return null
        }
        val enabled = values["enabled"] as? Boolean ?: return null
        val hour = exactInt(values["hour"]) ?: return null
        val minute = exactInt(values["minute"]) ?: return null
        val studiedToday = values["studiedToday"] as? Boolean ?: return null
        val dueCount = values["dueCount"]?.let(::exactInt)
        if (values["dueCount"] != null && dueCount == null) return null
        if (hour !in 0..23 || minute !in 0..59 || (dueCount != null && dueCount < 0)) {
            return null
        }
        return RecallReminderSettings(enabled, hour, minute, dueCount, studiedToday)
    }

    fun widgetSnapshot(arguments: Any?): RecallWidgetSnapshot? {
        val values = arguments as? Map<*, *> ?: return null
        if (values.keys != setOf("dueCount", "updatedAtEpochMs")) return null
        val dueCount = exactInt(values["dueCount"]) ?: return null
        val updatedAt = exactLong(values["updatedAtEpochMs"]) ?: return null
        if (dueCount < 0 || updatedAt <= 0) return null
        return RecallWidgetSnapshot(dueCount, updatedAt)
    }

    private fun exactInt(value: Any?): Int? {
        val number = value as? Number ?: return null
        val long = number.toLong()
        if (number.toDouble() != long.toDouble() || long !in Int.MIN_VALUE..Int.MAX_VALUE) {
            return null
        }
        return long.toInt()
    }

    private fun exactLong(value: Any?): Long? {
        val number = value as? Number ?: return null
        val long = number.toLong()
        if (!number.toDouble().isFinite() || number.toDouble() != long.toDouble()) return null
        return long
    }
}
