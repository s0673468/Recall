# Android offline/sync reliability hunt — 2026-10-23

Read README and all earlier `docs/*hunt*.md` first. No repository AGENTS.md
exists. PR #174 is already in this checkout; its four changed files are
untouched. Scope is the shared Dart review controller used by Android. Existing
tests, dependency pins, backend/schema, remotes and Git metadata are unchanged.
No personal data, credentials, live accounts, network services in tests, fleet
checks, messages, Apple builds/tests or device operations were used.

## Fixed findings

1. **An uncertain-save retry could change the meaning of an event ID.**
   The controller retained only the uncertain review's ID and card/owner. A
   retry recomputed its FSRS result, timestamp, elapsed time and rating. If the
   original append had committed, storage kept the original payload while the
   session used the retry's rating: retrying a validation Again with Good could
   remove a validation that the server still considered failed. If the append
   had not committed, the reused ID instead acquired the new payload. Clock
   rollback also changed the displayed last-review time independently of the
   durable review. The controller now retains and reuses the original payload
   and rating for that uncertain action. A retry completes the original tap.
   Definite refusals still permit a fresh action as before.

2. **A local ACK failure could leave startup loading forever.**
   The startup outbox flush ran outside queue-load recovery. After the server
   committed a review, either a refused local drain or a thrown drain reply
   escaped `initialize()` with `loading` still true. Startup now contains this
   failure, settles loading and offers Retry with a pending-study-actions error.
   It does not infer a radio failure from a storage failure. Corrupt outboxes
   retain their existing separate recovery path. Reconstructing the store and
   retrying drains the original event without a second server effect.

3. **Delivery of an uncertain save could reopen unsafe local Undo.**
   Reconnect can deliver and drain the uncertain action while its original card
   remains visible. If the connection drops again before the user retries,
   retry previously recreated that ID as an unsent entry. Local Undo could
   remove it and rewind the session even though the server review already
   existed. The sender now remembers the attempted marker for the uncertain
   action; retry preserves that marker and does not offer Undo. Reviews that
   were never attempted retain their existing local Undo behavior.

All fixes are in `lib/features/review/application/review_controller.dart`.
`test/android_sync_recovery_hunt_test.dart` adds nine synthetic cases: eight
regressions and a passing control for refused pre-send attempt markers. It uses
an in-memory native-preferences fake and the existing fake API/server; no HTTP
client is constructed. Tests cover before/after-commit uncertainty, different
rating buttons, clock changes, validation snapshot reconstruction, reconnect
before retry, ACK refusal/lost replies, offline Undo and exact-once replay.

## Verification

Copied the installed pinned Flutter 3.47.1 SDK into this checkout. All commands
used `./tool/flutterw`; mutable SDK/package/config/temp state stayed local:

```sh
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
export PYTHONDONTWRITEBYTECODE=1
export RECALL_FLUTTER_ROOT="$PWD/.dart_tool/android-sync-hunt/sdk/flutter-3.47.1"
export DART="$RECALL_FLUTTER_ROOT/bin/dart"
export PATH="$RECALL_FLUTTER_ROOT/bin:$PATH"
export PUB_CACHE="$PWD/.pub-cache"
export XDG_CONFIG_HOME="$PWD/.dart_tool/android-sync-hunt/config"
export XDG_CACHE_HOME="$PWD/.dart_tool/android-sync-hunt/cache"
export TMPDIR="$PWD/.dart_tool/android-sync-hunt/tmp"
```

| Exact command | Result |
| --- | --- |
| `./tool/flutterw pub get --enforce-lockfile` | Exit 0; lockfile unchanged. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile test/android_sync_recovery_hunt_test.dart` against original controller, before adding the final Undo regression | Exit 1; seven regressions failed, one control passed. Fixed controller restored immediately. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile test/android_sync_recovery_hunt_test.dart --plain-name 'offline retry of a delivered uncertain save cannot reopen Undo'` before fix 3 | Exit 1; Undo was available for an already-delivered review. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile test/android_sync_recovery_hunt_test.dart test/duplicate_review_delivery_safety_test.dart test/review_refused_save_test.dart test/outbox_batch_attempt_test.dart test/recall_undo_test.dart` | Exit 0; 74 passed. |
| `./tool/flutterw analyze --no-pub` on final source | Exit 0; no issues found. |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile` on final source | Exit 0; 1,455 passed, four skipped. |
| `git diff --check` | Exit 0. |

## Remaining boundaries

No additional new defect was confirmed for this focused change. Existing
limitations remain: ordering across devices still trusts their review clocks;
the pre-RPC fallback cannot make its separate writes transactional; remote Undo
still needs an atomic server contract. These are documented in README and the
earlier hunts and were not repeated as fixes here. Existing conflict, timezone,
timeout, parking, restart and replay tests run in the full suite.

Acceptance is synthetic controller/storage execution. It does not prove physical
Android process-kill/radio behavior or deployed PostgreSQL/Recall Hub behavior.
No APK, native Android code or iOS target was built. The runner owns the commit.
