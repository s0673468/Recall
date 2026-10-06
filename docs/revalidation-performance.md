# Material revision discovery

Fresh queue reads scan material-revision candidates in ID order, requesting up
to 250 cards at a time. The existing 5,000-candidate scan ceiling and 20-card
priority batch remain unchanged. A server can return fewer rows than requested;
the next offset advances by received rows, and only an empty page ends a scan.

Successful acknowledgement history is read in ordered pages of up to 1,000
rows. The append-only log's unique ID keeps paging stable across equal review
timestamps. Each card needs a successful rating strictly after its own newest
valid revision. Discovery retains only an acknowledged-ID set rather than all
historical timestamps. It stops early when every candidate is acknowledged.
There is no persistent cache: a new marker or review is visible on the next read.

Mostly acknowledged collections should need fewer serial network requests before
the fresh queue arrives. Larger responses and longer query URLs trade against
those round trips. Small collections can need an extra empty-page request, and
collections with much repeated history can need more acknowledgement reads than
the formerly truncated query. Candidate scanning remains bounded; complete log
discovery depends on the amount of qualifying history and the server row cap.
Optional discovery failure still falls back to the ordinary queue and retries
on the next read. It never changes scheduling fields or writes to the backend.

## Reproduce checks

Use the repository's pinned Flutter wrapper:

```sh
./tool/flutterw test --no-pub --concurrency=1 \
  test/content_revalidation_test.dart \
  test/recall_revalidation_holdout_test.dart
./tool/flutterw test --no-pub --concurrency=1 \
  test/recall_revalidation_benchmark_test.dart
```

The independent holdout uses invented data and checks all card fields, strict
markers/time/ratings, filters, hidden cards, queue order/deduplication, scan and
batch limits, short server responses, repeated history, invalidation, failures
and interrupted-read retry. The development benchmark runs the actual API with
invented 450-card data and emits request counts, response/query sizes, full queue
semantics, timings and client RSS. `RECALL_MODEL_REPEATS` accepts 1–30 independent
clients; `RECALL_MODEL_DELAY_MS` accepts 0–100 milliseconds per synthetic request.
Every observation, including the first, is retained. A delay model is a component
experiment and cannot establish real startup latency or device acceptance.

Compare equivalent source/input/toolchain/cache states and preserve full results.
Check real owning-device fresh reads, normal worker activation, interruptions,+freshness and resource costs before claiming user-visible latency gains. Cached
asset startup is not storage-cold startup; client RSS is not whole-job memory.
Report p95 only with at least 20 observations and p99 with at least 100.
