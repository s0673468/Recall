# Recall product acceptance

This is the repeatable product inventory and local acceptance contract for
Recall. It covers the complete user-facing surface in this repository. The
fixture is local, synthetic, deterministic, and cannot connect to production.

## Acceptance boundary

Recall has one product role: an authenticated learner. The same person also has
a signed-out state. There is no admin, authoring, guest, sign-up, password-reset,
or onboarding surface in this app.

The local fixture uses production-like volume and the normal app shell:

- 1,600 cards across 32 decks;
- 28 automatic technical decks and 4 manually opened curricula;
- 12,000 review-log rows across 190 days;
- 72 concept nodes and 72 primers;
- due, new, lapsed, long-text, HTML, cloze, LaTeX, SVG, revalidation, empty,
  offline, and partial-failure data.

All identifiers, emails, card text, review history, and credentials are
synthetic. `SanitizedRecallApi` overrides every exercised network method and
uses an invalid `.invalid` host as a final fail-closed boundary. The harness
does not read local production configuration, secure sessions, or user data.

Run the executable acceptance suite with:

```bash
./tool/flutterw test --no-pub test/production_scale_acceptance_test.dart
./tool/flutterw build web --debug --no-pub -t tool/recall_acceptance.dart
```

The web harness accepts `RECALL_ACCEPTANCE_SCENARIO=rich`, `empty`, `offline`,
`partial_stats_failure`, or `signed_out` as a compile-time Dart define.

## Routes and platform shells

| Surface | Entry | Acceptance criteria | Finite risk cases |
|---|---|---|---|
| Startup | App launch | Loading mark appears; success swaps to auth or shell; startup failure shows a readable error and states that offline data was retained. | Slow loader; loader exception; disposal while loading. |
| Auth | Signed-out launch | Email and password accept input; password is obscured; Sign in has a pending state; success opens Study; a failure stays on the form with readable feedback. | Empty field; invalid credentials; double submit; restored session; external sign-out. |
| Study | Default tab and `recall://study` | Study is the initial route. The only accepted deep link selects Study. Unknown schemes, hosts, paths, queries, and ports do nothing. | Cold link; warm link from another tab; repeated link; malformed link. |
| Decks | Bottom tab, iOS tab, or Android rail | Selects Decks and refreshes counts without replacing an in-progress card. | Re-select current tab; count failure; narrow phone; wide Android rail. |
| Stats | Bottom tab, iOS tab, or Android rail | Selects Stats and refreshes independent sections. | One section fails; other sections remain usable; re-select current tab. |
| Read | Bottom tab, iOS tab, or Android rail | Selects Read and refreshes primers/remediation. | Empty library; load failure; long list; re-select current tab. |
| Settings | Study header gear | Pushes Settings; platform back returns to the same Study session. | Back during an update; long deck list; large text. |
| Primer | Read row, remediation row, or Stats concept action | Pushes one primer; back returns to its source without changing review state. | Missing SVG; long title/body; unsupported markup. |
| System back | Android/back gesture | From Decks, Stats, or Read, first back selects Study. From a pushed page, back pops that page. | Back during tab animation; repeated back. |

Platform equivalence is finite: Material bottom navigation covers web and
narrow Android; Cupertino navigation and modals cover native iOS; Android at
600 logical pixels or wider uses the rail. The content and state contracts are
shared.

## Study inventory

| Feature or control | Acceptance criteria | Finite risk cases |
|---|---|---|
| Queue strip | Due, New, and Session show the current filtered queue and session count. | Zero; large backlog; direct deck; automatic stream; offline snapshot. |
| Offline/sync pill | Offline is explicit. Pending writes show a bounded syncing count and disappear only after acknowledgement. | Restart; reconnect; foreground sync; failed acknowledgement. |
| Question card | Rich text is readable and scrollable. HTML, cloze, code, lists, LaTeX, missing media, and long content do not crash or clip. | 320 px width; 2x text; malformed markup; revised content for the same card id. |
| Show answer | Reveals the current card's answer and replaces itself with ratings. It cannot rate or advance by tapping card content. | Repeated tap; long answer; content revalidation card. |
| Again, Hard, Good, Easy | Each button has a predicted interval and accessible label. One visible card can record at most one rating, even under rapid taps. | Double tap; offline outbox; last card; sync failure; rating while undo runs. |
| Undo last rating | Restores the immediately previous local card state and session count. Hidden when nothing is undoable and disabled while undo is running. | Last card; offline pending review; completed screen; second tap. |
| Flag card | Opens a platform modal without advancing the card. Wrong, Confusing, Too long, and Duplicate enqueue the exact reason and confirm success. | Cancel; offline queue; flag sync failure; repeated open. |
| Settings gear | Opens Settings without replacing or rating the current card. | Open before reveal; open after reveal; return with changed preferences. |
| Catch-up: Start catch-up | Activates the bounded daily catch-up plan and shows progress. | Large backlog; persisted plan; daily cap; next-day reset. |
| Catch-up: Show all | Dismisses the offer and preserves the full due queue. | Repeated action; restart; direct deck. |
| Catch-up paused: Reload | Rechecks the queue after the daily cap. | Offline; next day; server error. |
| Done: Keep going | Loads only bonus work inside the next-day horizon and preserves pending writes. | Empty ahead queue; offline; repeated exhaustion. |
| Done: Reload | Rechecks due work without losing the one-level undo affordance before reload. | No work; newly due work; refresh error. |
| Load error: Retry | Retries without clearing the owner-scoped snapshot or outboxes. | First launch offline; corrupt cache; restored snapshot. |
| Remediation row | Opens the attributed primer. Completion removes only that remediation entry. | Missing primer; already read today; offline local completion. |

## Decks inventory

| Feature or control | Acceptance criteria | Finite risk cases |
|---|---|---|
| Pull to refresh | Reloads per-deck due/new counts and keeps the list usable while refreshing. | Offline; partial RPC error; repeated pull. |
| Automatic review hero | Shows aggregate counts for automatic decks only. Tap selects the automatic stream and returns to Study. | No automatic decks; zero counts; stale counts. |
| Core deck rows | Every automatic deck row shows its normalized hierarchy, membership, and available counts. Tap opens that exact deck. | 28-row production list; long name; zero due; null count. |
| Optional curriculum rows | Manual decks are visibly separate and say Open manually. They never enter automatic queues or forecasts. Tap opens only that deck. | Plain Portuguese name; `Opt-in::`; experimental name; very long name. |
| Count error: Retry | Only the count strip reports failure; deck navigation remains available; Retry reloads counts. | Server cap; RPC absence; reconnect. |

All generated core rows share one row component and callback contract. The
acceptance partitions are core, plain-manual, prefixed opt-in, and long-name
manual; the 32-row fixture exercises every partition and list virtualization.

## Stats inventory

| Feature or control | Acceptance criteria | Finite risk cases |
|---|---|---|
| Retention 30d / 90d | The segmented control recomputes the headline from the chosen window without refetching unrelated data. | No reviews; all Again; boundary timestamp; 12,000 rows. |
| Current session | Reviewed, Due now, and New left track live Study state. | Undo; direct deck; completed session. |
| Last 30 days | Recall, streak, and review count use local calendar boundaries. | Time-zone edge; missing days; today-only activity. |
| Activity heatmap | Shows the last 26 weeks without overflow or silent row truncation. | 12,000 rows; empty history; dense day. |
| Work ahead | Shows the automatic-deck two-week forecast. Manual curricula are excluded. | More than 500 cards; null due; partial query failure. |
| Concepts | Ranks weak concepts using review/tag/node inputs and shows coverage. | Missing tags; missing metadata; fewer samples; 72 concepts. |
| Browse concept primers | Opens the primer library from the concept panel. | No primers; long primer list. |
| Independent loading/error states | Retention/history/heatmap, forecast, and concepts resolve independently. One failure cannot blank another. | Forecast-only failure; concept-only failure; retry. |
| App switcher | Appears only on supported web-family hosts and retains Recall as current. | Unsupported native target; narrow width. |

Review-log, note-tag, due-date, and due-queue reads use keyset pagination. The
regression fixture forces a second page after 500 rows and verifies the stable
timestamp/id or guid cursor.

## Read and primer inventory

| Feature or control | Acceptance criteria | Finite risk cases |
|---|---|---|
| Pull to refresh | Reloads the review attribution, tags, nodes, primers, and remediation queue. | One input fails; offline; repeated pull. |
| Today's reading rows | Shows primers attributed to concepts reviewed today and opens the selected primer. | Nothing studied; duplicate concept; missing page. |
| Reread rows | Shows queued remediation before today's ordinary rows and removes an item only after the primer returns. | Same concept in both sets; missing metadata; next-day expiry. |
| Primer search input | Filters title and module case-insensitively. | Empty query; no match; punctuation; long query. |
| Clear search | Appears only for non-empty input and restores the full library. | Rapid type/clear; no-match state. |
| Primer row | Opens exactly the selected node. A 72-row list remains scrollable. | Long title; missing module; list virtualization. |
| Primer body | Renders safe supported HTML, LaTeX, and optional SVG with readable wrapping. | Missing/broken SVG; long body; 2x text; back navigation. |
| Load error | Keeps pull-to-retry available and does not affect Study state. | Offline cold start; malformed response. |

## Settings and account inventory

| Feature or control | Acceptance criteria | Finite risk cases |
|---|---|---|
| Desired retention slider | Shows the live percentage and workload estimate; commits once at drag end. | Minimum; maximum; interrupted drag; offline save. |
| New cards minus/plus | Changes one step, clamps from 0 through 999, and persists the latest value. | Rapid taps; both bounds; cloud failure; restart. |
| New-card order | Oldest, Newest, and Random are mutually exclusive and affect the next queue load. | Change during a session; restart; offline pending value. |
| Daily reminder switch | Requests permission when enabling; schedules only when due work is known and nothing was studied today; disabling cancels it. | Denied permission; unknown activity; zero due; account switch. |
| Reminder Settings action | On permission denial, opens the app's platform notification settings when available. | Missing settings activity; repeated request; native exception. |
| Reminder time | Opens Material or Cupertino time selection and reschedules an enabled reminder. Cancel changes nothing. | 00:00; 23:59; disabled state; day boundary. |
| Set override | Creates a per-deck new-card override from the global default. | 32 decks; long name; offline save. |
| Override minus/plus | Changes and clamps the selected deck only. | 0; 999; rapid taps; simultaneous global change. |
| Use default | Removes only that deck override. | Already default; cloud failure; restart. |
| Sign out | Shows a confirmation modal. Cancel stays signed in. Confirm signs out only after durable review and flag outboxes are empty. | Pending writes; sync failure; external sign-out; next account. |

Preferences, snapshots, review outboxes, flag outboxes, catch-up state, and
remediation state are scoped by a one-way hash of the authenticated owner id.
The first owner after upgrade can claim legacy unscoped review state once.
Later owners cannot see it. Malformed pending preferences are preserved under
the same hashed owner scope and removed from the live pending slot so cloud
recovery can continue.

## Native, PWA, and accessibility inventory

| Feature or control | Acceptance criteria | Local evidence | Remaining boundary |
|---|---|---|---|
| iOS/Android due widget | Signed out shows an open/load state. Signed in shows due count, singular/plural label, updated/stale freshness, and opens `recall://study`. A failed native update must be retried even when the snapshot is unchanged. | Dart bridge regression tests; Swift/Kotlin contract tests; Android instrumentation APK builds. | Widget rendering and tap on physical iPhone/Android. |
| Study reminder notification | Contains no card/deck content, opens Study, delivers only when eligible, and offers settings recovery after denial. | Controller, Swift, Kotlin, and configuration tests. | Permission prompt, delivery, and tap on physical devices. |
| Android launcher shortcut | Opens only the exact Study deep link. | Manifest/configuration contract tests. | Installed-launcher tap. |
| Background/foreground sync | Requests a bounded sync, keeps failures non-fatal, and never exports raw error or user content. | Dart/native tests and operational envelope tests. | OS scheduler execution on installed apps. |
| PWA boot | Shows an immediate splash, surfaces boot errors, loads the local CanvasKit assets, and avoids registering a service worker on localhost. | Debug and release web builds; local browser pass. | Deployed cache upgrade/offline behavior. |
| Zoom and large text | The PWA does not disable browser zoom. Core flows fit at 320×640 with 2x text and rating controls remain reachable. | Static viewport regression; widget visual tests. | VoiceOver/TalkBack and browser pinch zoom on real hardware. |

## Bug reproduction and disposition

| ID | Reproduction evidence | Shared cause | Disposition |
|---|---|---|---|
| RPA-001 | Rapidly call Good twice before the first async rating finishes; session count was 2 for one visible card. | Review mutation had no in-flight serialization. | Fixed with a controller lock and disabled rating controls. Regression: `a rapid double rating records the visible card only once`. |
| RPA-002 | Make the native widget update throw, then publish the identical snapshot; update attempts stayed at 1. | Dedupe state advanced before the platform acknowledged the update. | Fixed by committing dedupe state only after success and queueing one latest retry. Regression: `retries an unchanged snapshot after a transient update failure`. |
| RPA-003 | Save all-decks snapshot, then a direct-deck snapshot; the all-decks cache was replaced. | Every filter wrote the same snapshot key. | Fixed with per-deck snapshot keys and scoped clear. Regression: `all-decks and direct-deck snapshots remain independent`. |
| RPA-004 | Account A writes a snapshot/outbox, signs out, and account B starts; unscoped storage made A's state readable. | Review local state had no authenticated owner namespace. | Fixed with hashed owner scopes and a one-owner legacy claim. Regressions cover isolation, in-flight cleanup, and migration. |
| RPA-005 | Request 501 reviews, tags, due dates, or due cards behind a 500-row server cap; results stopped at 500 or offset paging could skip a row during mutation. | Aggregate reads were unpaged and the due queue used a mutable offset. | Fixed with stable keyset cursors. Regressions force page 2 for every data family. |
| RPA-006 | Seed a malformed owner pending preference plus a valid local mirror and cloud value; every sync returned early at the corrupt record. | The unreplayable pending slot remained permanently authoritative. | Fixed by preserving the malformed raw value in owner-scoped recovery storage, clearing only the unchanged live slot, then refreshing cloud state. |
| RPA-007 | Inspect the PWA viewport and attempt browser zoom; `user-scalable=no` and `maximum-scale=1` explicitly disabled it. | Boot HTML overrode the user's accessibility control. | Fixed by removing both restrictions. Static regression protects the viewport contract. |
| RPA-008 | Hold account A's first review or flag delivery open, replace the API session with account B while A's storage release is delayed, then release the delivery; the next A entry was sent through B's session. | Outbox draining checked only the storage namespace, not the authenticated user that began the flush. | Fixed by binding each delivery to both the API user and hashed owner scope. Regressions preserve A's undelivered suffix for reviews and flags. |
| RPA-009 | Hold account A's widget update open, sign out, sign in as B with the same aggregate, then release A's update; B's update was deduplicated and the queued clear became the final native state. | Widget acknowledgement used a shared signed-in boolean and shared queued snapshot across auth sessions. | Fixed with an in-memory session generation and owner identity. Regressions cover queued sign-out/sign-in and direct account replacement. |

## Clean-pass rule and blocked evidence

A local clean pass requires the production-scale suite, all focused regression
files, analyzer, full Flutter test suite, and release web build to pass on the
same commit. Visual acceptance must traverse the compiled rich fixture at phone
and desktop sizes with no runtime exception or clipped primary control.

The following are not represented as local passes:

- native widget, reminder, shortcut, background scheduling, VoiceOver, and
  TalkBack behavior require installed physical devices;
- TestFlight installability requires a merged build and App Store Connect;
- deployed PWA cache upgrade/offline behavior requires the production host;
- Undo deliberately restores a local pre-rating snapshot. Eliminating its
  documented cross-device conflict needs a server row-version schema change.

No production schema, storage, credentials, deployment, or user data may be
changed as part of this local acceptance run. Those boundaries require an
explicit approval and a separate live readback.
