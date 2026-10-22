# Review startup and loop speed hunt

Two production paths changed: published review queues now share a lazy prefix
index for due/new counters, and active catch-up presentation selects only the
remaining daily allowance instead of sorting the whole backlog. The latter runs
both on cached startup and on selecting catch-up. FSRS scores, stable ties,
validation-card priority, the new-card gate, and daily limits are preserved.
The general `orderDue` helper also traverses arbitrary iterables once instead of
repeatedly evaluating `length` and `elementAt`.

Reproduce the synthetic benchmark with the pinned Flutter SDK and dependencies:

```sh
./tool/flutterw test --no-pub --reporter=expanded \
  --dart-define=RECALL_SPEED_BENCHMARK=true \
  test/review_speed_benchmark_test.dart
```

The fixture generates 2,000 and 20,000 cards, two decks, 10% new cards, a fixed
clock and repeatable FSRS inputs. SharedPreferences is mocked and the API is an
in-process fake; no network, credentials, or personal data are used. One warm-up
and seven measured runs produce medians. Paired legacy/optimized kernels
alternate execution order in the same process. The full-sort kernel is frozen
in the benchmark; counter scanning and indexing read the same published queue.
Equality/checksum assertions run outside timing. No test asserts wall time.

Measured on this Linux checkout with Flutter 3.47.1 / Dart 3.13.1, in milliseconds:

| Paired operation | 2k before | 2k after | 20k before | 20k after |
| --- | ---: | ---: | ---: | ---: |
| Due/new counters over 1,000 index/metadata ticks | 24.923 | 0.078 | 263.244 | 0.239 |
| Full-sort daily selection → bounded daily selection | 0.808 | 0.618 | 7.972 | 4.142 |

Counter timing includes building the prefix on the first read, but excludes
copying the newly published queue. That copy and one prefix allocation cost
O(n) per replacement; subsequent counters, including backward Undo positions,
cost O(1) and reuse the same index. The regression test counts exactly n
`isNew` reads across repeated actions at both sizes. Queue copies own immutable
card lists so a caller cannot invalidate the counts by mutating its input.

Daily selection retains only the remaining allowance (normally at most 20
ranks), with bounded insertion instead of a full n-card rank list and sort.
It returns the same cards and stable tie order as the full-sort reference,
including partial/exhausted daily caps. No persistence, transport, scheduling,
or card/article content format changed.

The same fixture exercises real controller/store actions. These are current
in-process medians, including mock storage serialization and controller work:

| Controller action | 2k ms | 20k ms |
| --- | ---: | ---: |
| Cached startup to first published card, ordinary stream | 8.725 | 98.411 |
| Cached startup to first published card, active catch-up | 8.295 | 99.791 |
| Grade, offline and durably appended to mock storage | 0.927 | 1.994 |
| Undo, removed from mock outbox and presentation restored | 0.415 | 0.388 |
| Select catch-up | 0.573 | 3.269 |
| Switch to the second deck | 2.133 | 3.563 |
| Sync a 20-review offline session through the fake API | 3.235 | 2.403 |

Whole-controller runs before/after the change varied with host load, so they
are coverage and profiling observations, not end-to-end speedup claims. First
card means a controller notification, not a rendered Android frame. Large
snapshot JSON decoding still runs synchronously; durable outbox JSON writes
remain unchanged. Sync already batches attempted markers and acknowledged
removals; changing its durability protocol was outside these two fixes.
Native preferences, network latency, APK launch and physical-device timings
are not measured by this test.

The native checkpoint experiment was separately re-pinned: exact Controller,
checkpoint result, patch, and fixture hashes agree across its contract,
workflow and guards. Only checkpoint hunk positions changed. The sole existing
test edit refreshes its explicit patch digest as required by this ticket;
assertions and acceptance conditions are unchanged. Fresh emulator receipts
are still required for that experiment; no native-checkpoint speedup is claimed.
