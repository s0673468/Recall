# Synthetic Dart sync lab bridge

This adapter imports the production `LocalReviewStore`, `RecallApi`, and
`review_replay.dart`. It does not copy their policies or access real learning
data. The only HTTP client is an injected `MockClient`: requests are forwarded
as JSON to a controlling owned scratch-SQL runner, never sent to the placeholder
`.invalid` URL. No response or default success is fabricated by the adapter.

## Admission and launch

Use a fleet-admitted Flutter host, the exact pinned source, existing lockfile,
and an isolated synthetic fixture directory. Do not download tooling on M1.
The coordinator must create a fresh private directory, start with `umask 077`,
and write `.sync-lab-owned` containing exactly
`recall-sync-lab-synthetic-v1\n`. It must listen on an owned Unix socket first.

```
SYNC_LAB_SOCKET=/owned/fixture/bridge.sock \
SYNC_LAB_PREFS_DIR=/owned/fixture/preferences \
flutter test --no-pub tool/sync_lab_dart/schedule_driver_test.dart
```

The adapter emits `{"kind":"ready","protocol":"recall-sync-lab-dart-v1"}`
over the socket, then accepts one JSON object per line. Flutter reporter output
does not share this socket. A worker shuts down via `{"id":"end","op":"shutdown"}`.
The test timeout is 25 minutes; the supervisor must impose its shorter remaining
stage/campaign bound and preserve uncertain SQL requests before killing a worker.

## Commands

Every device command has `id`, `op`, and `deviceId` (ASCII letters, digits,
underscore or hyphen, 1–80 characters). Replies preserve `id` with `ok`, `result`
or `errorType`/`error`, and the real-client and persistence trace. `ok` means the
command returned normally; **it does not mean a schedule passed**.

* `open`: optional `userId`; omitting it starts the real legacy unscoped store.
* `enqueue`: `entry` in production format (`client_id`, `card_id`, `guid`,
  `rating`, `last_review`, `stability`, `difficulty`, `due`, `state`, `reps`,
  `lapses`, `lapsed`, `elapsed_ms`, `device`). Synthetic placeholders only.
* `enqueueFlag`: `entry` with the production flag shape.
* `undo`, `undoFlag`, `markAttempted`: `eventId`.
* `status`: real outbox, flag list, active owner scope, and install ID.
* `switchAccount`: `userId`, or null to release the active local namespace.
* `reopen`: discard the store/cache object and reload the same on-disk values.
* `failNextWrite`: fail the next preferences write, returning false.
* `flush`: mark attempted, invoke real `RecallApi.applyReview`, then acknowledge
  the prefix. Optional `failAckWrite:true` fails the first acknowledgement write
  after the actual transport response; the command then fails explicitly.
* `applyReview`: `entry`, direct production API call for explicit transport cases.
* `remoteUndo`: `entry`, real API call expected to fail before any transport.
* `legacyMerge`: `entry` and `server`, invokes the documented legacy helper and
  reports `countsAsSchedule:false`.
* `parallel`: `commands`, concurrent same-device enqueue/undo/markAttempted/
  enqueueFlag/undoFlag calls. Device IDs on children are fixed to the parent.

Commands are serialized across devices because SharedPreferences exposes a
process-global platform singleton. The `parallel` operation exercises the actual
per-store mutation lock. Separate Hub/browser/SQL actors may interleave while
this driver awaits a transport response. Do not claim this driver's command loop
proves a concurrent account change during an HTTP await.

## Transport frames

Real API requests emit:

```json
{"kind":"transport","requestId":1,"deviceId":"d0","userId":"synthetic-owner","method":"POST","path":"/rest/v1/rpc/apply_review","query":{},"body":"{...real p_* parameters...}"}
```

The coordinator must assert its scratch target identity, execute the actual SQL
as the corresponding RLS role/owner, and send either:

```json
{"kind":"transport_result","requestId":1,"ok":true,"status":200,"body":"77","headers":{}}
```

or `ok:false,error:"acknowledgement lost"`. `body` is a JSON-encoded **string**;
HTTP error responses use their real status and PostgREST-shaped JSON body.
Replies are required within 30 seconds. Connection/SQL errors are never converted
to successful responses. RPC-unavailable responses intentionally enter the real
API's legacy gateway; all subsequent GET/PATCH/INSERT requests must be executed
against the independent scratch fixture, or that case remains untested.

## Evidence boundaries

The file adapter writes/reloads real disk data but substitutes the preferences
platform layer. It is **not** real IndexedDB/localStorage or native plugin proof.
`flush` is harness orchestration of real store/API methods, not the app controller
itself. `userId` labels synthetic scratch RLS identity; this driver does not claim
real Supabase authentication/session-refresh behavior. Account namespace and
never-attempted local undo calls are production code. Other adapters must cover
the real web/controller/account-await surfaces before complete acceptance.

The standalone `dart run tool/sync_lab_dart/replay_driver.dart` reads JSONL
`{id,entry,server}` and invokes the production merge helper. It exists to compare
legacy semantics independently; its output always says `countsAsSchedule:false`.
Timestamp-equality divergence is documented legacy behavior and must not be
promoted to a production RPC defect without actual transport reachability.

No adapter execution, compilation, SQL result, or complete schedule acceptance
is implied by these files. The campaign coordinator owns those receipts.
