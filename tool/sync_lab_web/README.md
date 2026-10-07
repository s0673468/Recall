# Synthetic Flutter web schedule adapter

This entrypoint compiles the actual `ReviewController`, `RecallApi`,
`BrowserForegroundSyncCoordinator`, browser lifecycle platform and
`LocalReviewStore` with the real SharedPreferences web plugin. It is not the
native Dart adapter relabeled as a web device. No production code or scheduler
parameters are modified. FSRS is constructed with existing package defaults;
generated scheduling payloads enter the durable outbox directly.

Build only on an admitted compatible host, from the exact clean commit:

```text
flutter build web --release --no-pub --no-web-resources-cdn --target tool/sync_lab_web/main.dart --dart-define=SYNC_LAB_SOURCE_SHA=<40-hex-head> --output <owned-output>/flutter-web
```

Use the already installed pinned Flutter toolchain and resolved lockfile.
Reserve compilation separately (initial conservative request: 2 CPUs, 2 GiB
including descendants and margin; revise from actual admission/measurements).
Do not compile within the shared M1 coordination pool. Source, toolchain and
output hashes belong in the runner receipt; a supplied SHA is a label, not an
independent source attestation.

Launch only in a fresh synthetic browser context. Intercept static resources
from that compiled output, including CanvasKit assets, and reject unrelated
network requests. Separate devices need separate browser storage contexts;
tabs belonging to one device share its context. The host must install this
function before Flutter starts:

```javascript
window.recallSyncLabTransport = async (json) => {
  const frame = JSON.parse(json);
  // Forward this actual RecallApi HTTP request to the owned scratch SQL bridge.
  return JSON.stringify(await scratchTransport(frame));
};
```

Transport frames contain `kind`, `requestId`, `commandId`, `deviceId`, `userId`,
`method`, `url`, `path`, `query`, `headers`, `body`, and `surface`. A response is
`{ok:true,status:200,body:"<JSON>",headers:{...}}`; `{ok:false}` throws at the
real HTTP boundary. The adapter's MockClient replaces transport only: production
controller, SDK serialization, replay, durable storage and browser events run.
All credentials are locally generated synthetic expired-in-one-day session
tokens, never production credentials. Reads triggered by auth and refresh must
come from scratch rows, including empty settings/flags/logs when appropriate.

Wait until `typeof window.recallSyncLabCommand === 'function'`, then call:

```javascript
const reply = JSON.parse(await window.recallSyncLabCommand(JSON.stringify({
  op: 'open', commandId: 'schedule-1-open', deviceId: 'web-1',
  userId: '00000000-0000-4000-8000-000000000001'
})));
```

Operations:

- `open`: activate recovered synthetic auth, real account-change stream and
  browser coordinator. Controller starts normal asynchronous reads.
- `enqueue` / `enqueueFlag`: `entry` is a shared synthetic JSON event.
- `flush`: await the production controller review and flag flush loops.
- `wake`: await real foreground coordinator synchronization; hidden/offline
  state is read from browser APIs, not a driver boolean.
- `switchAccount`: `userId` string or null; genuine GoTrue event and store owner
  transition. Can run while an external transport callback is held to exercise
  the controller's actual asynchronous account race.
- `undo`: real durable-store `removeEntry(eventId)`; does **not** claim a UI
  rating/undo path. `controllerUndo` calls controller undo, but generated events
  injected directly into storage do not create a controller undo record.
- `refresh`: real controller load; `fetchQueue`: actual RecallApi paging.
- `readCardSnapshot`: `cardIds` array; real Supabase SDK SELECT including
  future-due cards for independent eventual-convergence comparison.
- `status`: durable outbox/flags, actual controller queue, auth/owner state,
  foreground pass count, transport trace and operation witnesses.
- `dispose`: stop coordinator timer/listeners, controller and SDK.

Replies are `{ok:true,result:...}` or `{ok:false,error:...}`. Controller flush
intentionally swallows offline errors, so an ok command is never proof of
delivery. Independently inspect pending entries, scratch SQL rows, invariant
witnesses and eventual snapshots. Status witnesses include earlier completed
commands; the current status command's witness appears on the following read.
Auth-driven loads can still be pending after `open`; explicit `refresh` plus
transport drain and loading-state checks establish a stable read barrier.

For persistence, reload the real page in its existing context and open again;
never substitute an in-memory preference backend. Calling open for a new
schedule does not reset storage. The owning runner must manage isolated
contexts or explicit synthetic cleanup without touching user profiles.

This adapter alone provides no accepted schedules and no UI-rate/undo witness.
The generated runner must attach actual browser commands and scratch SQL
receipts to each schedule. Compile or launch acceptance is not execution.
