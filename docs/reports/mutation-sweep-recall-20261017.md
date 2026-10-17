# Recall mutation sweep — 2026-10-17

Base inspected: `77cad1c7e6e8eecf6745cf6bca598ab543b71962`.

## Result and scope

32 deterministic, single-expression mutants: 20 killed by the selected existing
tests, 12 initial survivors. Eleven survivors now have precise regression tests;
the remaining survivor is equivalent for the reasons below. Final result:
**31 killed, 1 equivalent, 0 unresolved**. This is a scoped probe set, not an
exhaustive mutation score or a claim about all Recall code.

No real production bug was found. Production sources are byte-for-byte restored,
and existing tests are unchanged. Added 11 synthetic Dart tests and five Python
runner safety tests. No card/article content, user-derived fixtures, production
data, credentials, real accounts, or external APIs were used. Android/web scope;
Flutter runs exclude `apple-mobile`.

Repository inspection found no existing code mutation setup. The semantic-review
tag-mutation tool changes content metadata and is unrelated; it was not used.
`tool/mutation_sweep_recall.py` is the new bounded mutator. It checks for exactly
one source match, runs one mutant at a time, restores original bytes in `finally`,
and stops on timeouts or unclassified/compilation failures. Each run first proves
its unmutated baseline. Failed test expectations, rather than compiler failures,
establish the kills reported here. Safety tests cover restoration after success,
exceptions, KeyboardInterrupt and SIGTERM, missing/duplicate source matches, result
classification, timeout handling, and manifest consistency.

Maximum mutant concurrency was one, with one Flutter worker. The final full
Flutter suite uses two workers. Batches were 24 scheduling/storage/migration
probes, followed by eight pure replay probes. Sources were never mutated while
the final suite ran. Migration probes exercise owner-claim/copy decisions against
in-memory preferences; they do not execute database migrations or platform
storage. Replay probes use the transport-free merge helpers. This sweep does not
validate PostgreSQL transactions, RLS, browser persistence, or device delivery.

## Mutants and disposition

`K` means a test expectation killed the mutant; `S` means it survived the selected
tests. Source expressions and exact test arguments are in the checked-in mutator.
New tests live in `test/mutation_sweep_regressions_test.dart`.

| ID | Planted bug | Before | After / disposition |
| --- | --- | --- | --- |
| S01 | Stop incrementing review reps | K | K |
| S02 | Stop incrementing lapses | K | K |
| S03 | Exclude relearning from lapse eligibility | S | K: Again increments existing relearning lapses exactly once |
| S04 | Count lapses for ratings other than Again | K | K |
| S05 | Require a gap strictly greater than the learning step | K | K |
| S06 | Treat missing timestamps as the final learning step | S | K: due missing, last-review missing, and both missing restart at step zero |
| S07 | Reconstruct relearning as review | S | K: Hard stays relearning and schedules fifteen minutes |
| S08 | Only initialize new cards when stability is also absent/zero | S | K: new state ignores stale stability/timestamps for all four ratings |
| S09 | Reset custom weights when retention changes | S | K: synthetic custom weights survive and retention changes scheduling |
| S10 | Shift retrievability's requested instant forward one day | S | K: zero elapsed days gives 1; ten days at stability 10 gives 0.9 |
| O01 | Default new outbox entries to already attempted | K | K |
| O02 | Admit any marker other than true for undo | S | K: absent/null/unknown/true remain queued; only explicit false permits undo |
| O03 | Stop detecting integer/string wire-ID collisions | K | K |
| O04 | Admit ambiguous duplicate delivery identities | K | K |
| O05 | Ignore unequal lengths when comparing nested JSON lists | S | K: extra immutable list elements conflict, in either argument order |
| O06 | Admit empty string delivery IDs | K | K |
| O07 | Remove normalized timestamp day comparison | S | S: equivalent; explanation below |
| O08 | Admit whitespace-only legacy devices | K | K |
| O09 | Admit zero legacy card IDs | K | K |
| O10 | Mark every queued ID attempted rather than only requested IDs | K | K |
| M01 | Let another owner inherit legacy state | K | K |
| M02 | Overwrite existing scoped migration progress | K | K |
| M03 | Ignore completed migration markers | K | K |
| M04 | Accept whitespace-only owner IDs | S | K: reject before owner activation or any durable migration write |
| R01 | Invert explicit lapse flags | K | K |
| R02 | Stop accumulating server reps | K | K |
| R03 | Write counters when server review timestamp is unreadable | K | K |
| R04 | Remove same-instant replay suppression | K | K |
| R05 | Let older reviews win scheduling | K | K |
| R06 | Convert a null compare-and-swap version to zero | S | K: first replay preserves SQL-null predicate while initializing counters |
| R07 | Perform one extra compare-and-swap attempt | S | K: exact read/write bounds and conflict metadata at limits 1 and 4 |
| R08 | Treat a lost compare-and-swap as success | K | K |

### O07 equivalence

The retained anchored regex admits only four-digit years, two-digit months/days,
and UTC timestamps. `DateTime.tryParse` normalizes overflowing components. The
retained year/month comparisons require the normalized date to have exactly the
input year/month. A day outside that month's valid range (including zero) moves
to another month/year; its two-digit range cannot traverse a whole year and
return to the same month/year. It is therefore already rejected. A valid day
normalizes to itself. Removing the separate day comparison changes no accepted
identity under the other retained guards. No production simplification was made.

## Commands and evidence

All commands ran from the repository root. The installed pinned SDK could not
start because its cache is mounted read-only. A disposable copy was made inside
the repository with:

```sh
mkdir -p .dart_tool/mutation-sweep
cp -a --reflink=auto /home/ger/.cache/recall/flutter-3.47.1 .dart_tool/mutation-sweep/flutter
mkdir -p .dart_tool/mutation-sweep/home
```

Commands below used these repository-local environment values (passed inline):

```sh
export RECALL_FLUTTER_ROOT="$PWD/.dart_tool/mutation-sweep/flutter"
export PUB_CACHE="$PWD/.pub-cache"
export HOME="$PWD/.dart_tool/mutation-sweep/home"
```

| Command | Result |
| --- | --- |
| `./tool/flutterw --version` (original installed SDK) | Exit 1: read-only SDK cache; resolved with local SDK copy |
| `./tool/flutterw pub get` | Exit 0; locked dependencies resolved |
| `python3 tool/mutation_sweep_recall.py --phase before` | Exit 0; baseline 80 passed; original 24-entry manifest: 14 killed, 10 survived |
| `python3 tool/mutation_sweep_recall.py --phase after` | Exit 0; baseline 89 passed; original 24-entry manifest: 23 killed, 1 equivalent survivor |
| `python3 tool/mutation_sweep_recall.py --phase before --batch replay --ids R01 R02 R03 R04 R05 R06 R07 R08` | Exit 0; baseline 12 passed; 6 killed, 2 survived |
| `python3 tool/mutation_sweep_recall.py --phase after --batch replay --ids R01 R02 R03 R04 R05 R06 R07 R08` | Exit 0; baseline 23 passed; 8 killed |
| `python3 -m unittest discover -s tool/tests -p 'test_mutation_sweep_recall.py'` | Exit 0; 5 tests passed on final runner |
| `HOME="$PWD/.dart_tool/mutation-sweep/home" .dart_tool/mutation-sweep/flutter/bin/dart format test/mutation_sweep_regressions_test.dart` | Exit 0; formatted new Dart tests |
| `git diff --exit-code -- lib` | Exit 0; no production changes remain |

Each baseline and mutant uses the repository's own command:

```sh
./tool/flutterw test --no-pub --concurrency=1 --reporter=expanded --exclude-tags apple-mobile TESTS
```

`TESTS` is the exact corresponding list below. After-phase runs append
`test/mutation_sweep_regressions_test.dart`. Baselines use the sorted union of
their batch's test paths.

| Mutants | Test paths |
| --- | --- |
| S01–S10 | `test/recall_fsrs_test.dart` |
| O01–O10 | `test/recall_offline_store_test.dart test/local_server_ack_drain_test.dart test/legacy_review_delivery_upgrade_test.dart test/outbox_batch_attempt_test.dart` |
| M01–M04 | `test/local_owner_migration_retry_test.dart` |
| R01–R08 | `test/recall_multi_device_sync_test.dart` |

The first two invocations preceded expansion of the manifest from 24 to 32
probes. With the final manifest, `--phase before` reproduces all 32 existing-test
probes and `--phase after` reproduces all 32 with the new regressions. Before-phase
explicitly omits the new regression file even when it exists.

### Final validation

The full Flutter suite ran once, after all 11 regressions were added and all
production sources restored. `TMPDIR` was set to
`$PWD/.dart_tool/mutation-sweep` for these final commands.

| Command | Result |
| --- | --- |
| `./tool/flutterw test --no-pub --reporter=failures-only --exclude-tags apple-mobile --concurrency=2` | Exit 0; 1,119 passed, 2 skipped; all other tests passed |
| `./tool/flutterw analyze --no-pub` | Exit 0; no issues found |
| `python3 -m unittest discover -s tool/tests -p 'test_*.py'` | Exit 1; 145 tests, 1 failure, 1 skipped; existing scheduler-build check selected a read-only SDK via `PATH` |
| `DART="$PWD/.dart_tool/mutation-sweep/flutter/bin/dart" python3 -m unittest discover -s tool/tests -p 'test_*.py'` | Exit 0; 145 tests, 1 skipped; includes all 5 mutation-runner safety tests and the scheduler's 34,623-vector VM/JS parity check |
| `git diff --check` | Exit 0 |

The tooling-suite retry explicitly selects Dart from Recall's pinned SDK. No
test, expectation, or production code was changed in response to that environment
failure. Native Android builds, browser-only checks, and hosted CI were not run;
the verified surfaces here are the Flutter VM suite, static analysis, and local
tooling tests, including synthetic scheduler compilation/parity checks.

Raw baseline/mutant logs and JSON receipts are disposable artifacts under
`.dart_tool/mutation-sweep/{before,after}/`, with the replay batch in each
directory's `replay/` subdirectory. The durable result is this report and the
reproducible mutation manifest. The ignore exception is restricted to this
requested report. The disposable SDK copy and its temporary home were removed
after verification; ordinary ignored dependency/build caches and receipts remain
available for inspection. No servers or watchers were left running.
No push, PR, remote change, or direct commit was attempted;
the runner owns the commit because `.git` is read-only.
