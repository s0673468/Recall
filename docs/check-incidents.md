# Incidents that select extra checks

Only matching rows add checks. Keep this list at eight rows or fewer; prune an
item after 90 days without a matching change. The normal exact-head gate stays.

| Change trigger | Check | Incident |
|---|---|---|
| Note-tag paging or cursor comparisons | `test/recall_api_list_feedback_test.dart`, `tools/recall_sync/tests/test_concept_pagination.py` | #208: database collations could skip note tags (2026-11-13). |
| Study Undo or save ordering | `test/study_review_stability_test.dart`, `test/study_card_handoff_test.dart` | #199: Android Undo and card transitions broke (2026-10-26). |
| Daily done count / receipt merge | `test/daily_review_count_test.dart`, `test/daily_review_batch_receipt_test.dart` | #184: saved daily counts must survive reload and agree with Hub (2026-10-24). |
| Owner migration, sign-out or secure storage | owner-migration tests and `test/signout_isolation_test.dart` | #171/#190: delayed actions and account switches could expose stale state. |
| Offline retries / uncertain acknowledgements | `test/retry_corrupt_outbox_test.dart`, `test/duplicate_review_delivery_safety_test.dart` | #170/#175: uncertain sends must not lose or duplicate reviews. |
| Android reminders | `test/study_reminder_write_failure_test.dart`, Android reminder unit tests | #205: reminders must recur while Recall stays closed (2026-11-12). |
