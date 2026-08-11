package com.german.health_anki_flutter

import android.content.Context
import android.system.Os
import java.io.File
import java.io.FileOutputStream
import java.util.Calendar
import java.util.TimeZone
import org.json.JSONArray
import org.json.JSONObject

object RecallOperationalDiagnostics {
    private const val maxPayloadBytes = 64 * 1024
    private val requiredKeys = setOf(
        "schema",
        "timestamp",
        "level",
        "project",
        "component",
        "operation",
        "outcome",
        "cause_code",
        "retryable",
        "run_id",
    )
    private val optionalKeys = setOf("commit_sha", "exit_code", "duration_ms")
    private val components = setOf("framework", "background_sync", "foreground_sync", "auth")
    private val operations = setOf(
        "handle_framework_error",
        "handle_uncaught_error",
        "sync_pending",
        "observe_auth_state",
    )
    private val outcomes = setOf("started", "succeeded", "failed", "skipped")
    private val causes = setOf(
        "none",
        "flutter.framework_error",
        "flutter.uncaught_error",
        "sync.background_failed",
        "sync.foreground_failed",
        "auth.stream_error",
    )
    private val timestampPattern = Regex(
        "^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})(?:\\.\\d{1,6})?Z$",
    )
    private val runIdPattern = Regex("^[A-Za-z0-9_-]{1,64}$")
    private val commitPattern = Regex("^[0-9a-f]{7,64}$")

    fun isCanonical(payload: String): Boolean {
        if (payload.toByteArray(Charsets.UTF_8).size > maxPayloadBytes) return false
        return runCatching {
            val events = JSONArray(payload)
            events.length() <= 100 && (0 until events.length()).all { index ->
                validateEvent(events.optJSONObject(index))
            }
        }.getOrDefault(false)
    }

    fun write(context: Context, payload: String) {
        require(isCanonical(payload))
        val directory = File(context.noBackupFilesDir, "RecallDiagnostics")
        if (!directory.exists() && !directory.mkdirs()) {
            error("diagnostics directory unavailable")
        }
        Os.chmod(directory.absolutePath, 0b111000000)
        val destination = File(directory, "operational-events-v2.json")
        val temporary = File.createTempFile(".operational-events-v2.", ".tmp", directory)
        try {
            FileOutputStream(temporary).use { stream ->
                stream.write(payload.toByteArray(Charsets.UTF_8))
                stream.fd.sync()
            }
            Os.chmod(temporary.absolutePath, 0b110000000)
            Os.rename(temporary.absolutePath, destination.absolutePath)
            Os.chmod(destination.absolutePath, 0b110000000)
        } finally {
            temporary.delete()
        }
    }

    private fun validateEvent(event: JSONObject?): Boolean {
        event ?: return false
        val keys = buildSet {
            val iterator = event.keys()
            while (iterator.hasNext()) add(iterator.next())
        }
        if (!keys.containsAll(requiredKeys) || !requiredKeys.plus(optionalKeys).containsAll(keys)) {
            return false
        }
        if (event.optString("schema") != "operational-event/v2" ||
            event.optString("project") != "recall" ||
            event.optString("level") != "error" ||
            event.optString("component") !in components ||
            event.optString("operation") !in operations ||
            event.optString("outcome") !in outcomes ||
            event.optString("cause_code") !in causes ||
            event.opt("retryable") !is Boolean ||
            !isTimestamp(event.optString("timestamp")) ||
            !runIdPattern.matches(event.optString("run_id"))
        ) {
            return false
        }
        if (event.has("commit_sha") && !commitPattern.matches(event.optString("commit_sha"))) {
            return false
        }
        if (event.has("exit_code") && !isInteger(event.opt("exit_code"))) return false
        if (event.has("duration_ms")) {
            val duration = event.opt("duration_ms")
            if (!isInteger(duration) || (duration as Number).toLong() < 0) return false
        }
        return true
    }

    private fun isInteger(value: Any?): Boolean {
        val number = value as? Number ?: return false
        return number.toDouble().isFinite() && number.toDouble() == number.toLong().toDouble()
    }

    internal fun isTimestamp(value: String): Boolean {
        val match = timestampPattern.matchEntire(value) ?: return false
        val parts = match.groupValues.drop(1).take(6).map(String::toInt)
        val calendar = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            isLenient = false
            clear()
            set(parts[0], parts[1] - 1, parts[2], parts[3], parts[4], parts[5])
        }
        return runCatching { calendar.timeInMillis }.isSuccess
    }
}
