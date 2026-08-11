package com.german.health_anki_flutter

import android.content.Intent
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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
}
