#!/usr/bin/env python3
"""Sequential, exact-expression mutation probes for Recall's synthetic tests.

Run from the repository root. Each test run has one mutant, one Flutter worker,
and a timeout. Production files are restored in finally, including on interrupt.
An exclusive repository lock rejects overlapping sweeps before the baseline.
Logs and JSON results live in the ignored .dart_tool/mutation-sweep directory.
This is a bounded probe set, not an exhaustive mutation score.
"""

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
ENGINE = 'lib/features/review/application/fsrs_engine.dart'
API = 'lib/features/review/data/recall_api.dart'
CONTROLLER = 'lib/features/review/application/review_controller.dart'
STORE = 'lib/features/review/data/local_review_store.dart'
REPLAY = 'lib/features/review/data/review_replay.dart'
TESTS = {
    # The older calendar transport assumes a four-character `lte.` prefix;
    # strict-cutoff probes use transports that accept either wire operator.
    'queue_cutoff_edges': [
        'test/recall_api_queue_round_trips_test.dart',
        'test/recall_api_introduction_pagination_test.dart',
    ],
    'schedule_edges': [
        'test/recall_fsrs_test.dart',
        'test/review_date_boundaries_test.dart',
        'test/mutation_sweep_regressions_test.dart',
    ],
    'queue_edges': [
        'test/review_date_boundaries_test.dart',
        'test/recall_api_queue_round_trips_test.dart',
        'test/recall_api_introduction_pagination_test.dart',
    ],
    'controller_edges': [
        'test/recall_review_controller_test.dart',
        'test/review_date_boundaries_test.dart',
    ],
    'schedule': ['test/recall_fsrs_test.dart'],
    'outbox': [
        'test/recall_offline_store_test.dart',
        'test/local_server_ack_drain_test.dart',
        'test/legacy_review_delivery_upgrade_test.dart',
        'test/outbox_batch_attempt_test.dart',
    ],
    'migration': ['test/local_owner_migration_retry_test.dart'],
    'replay': ['test/recall_multi_device_sync_test.dart'],
}
REGRESSIONS = 'test/mutation_sweep_regressions_test.dart'
SCHEDULING_REGRESSIONS = 'test/review_scheduling_mutation_test.dart'


@dataclass(frozen=True)
class Mutation:
    id: str
    group: str
    path: str
    before: str
    after: str


MUTATIONS = [
    Mutation('S11', 'schedule_edges', ENGINE, 'stability: stability,', 'stability: c.difficulty,'),
    Mutation('S12', 'schedule_edges', ENGINE, 'difficulty: c.difficulty,', 'difficulty: 5,'),
    Mutation('S13', 'schedule_edges', ENGINE, 'lastReview: c.lastReview,', 'lastReview: null,'),
    Mutation('S14', 'schedule_edges', ENGINE, 'final gap = due.difference(lastReview);', 'final gap = lastReview.difference(due);'),
    Mutation('S15', 'schedule_edges', ENGINE, 'final learning = c.state != 2 && c.state != 3;', 'final learning = c.state != 2 || c.state != 3;'),
    Mutation('S16', 'schedule_edges', ENGINE, 'c.stability! > _parameters[2]', 'c.stability! > _parameters[1]'),
    Mutation('S17', 'schedule_edges', ENGINE, '? _parameters[2]\n        : c.stability;', '? _parameters[1]\n        : c.stability;'),
    Mutation('S18', 'schedule_edges', ENGINE, 'rating,\n      reviewDateTime: when,', 'Rating.good,\n      reviewDateTime: when,'),
    Mutation('S19', 'schedule_edges', ENGINE, 'reviewDateTime: when,', 'reviewDateTime: when.add(const Duration(days: 1)),'),
    # Equivalent with pinned fsrs 2.0.1: reviewCard overwrites input due using
    # reviewDateTime + interval; retrievability uses lastReview. Recall's step
    # reconstruction still reads the original ReviewCard.due in either case.
    Mutation('S20', 'schedule_edges', ENGINE, 'due: c.due ?? when,', 'due: when,'),
    Mutation('Q01', 'queue_cutoff_edges', API, ".lte('due', nowIso);", ".lt('due', nowIso);"),
    Mutation('Q02', 'queue_edges', API, 'final nowIso = now.toUtc().toIso8601String();', 'final nowIso = now.toUtc().add(const Duration(days: 1)).toIso8601String();'),
    Mutation('Q03', 'queue_edges', API, 'now.toUtc().add(horizon)', 'now.toUtc().subtract(horizon)'),
    Mutation('Q04', 'queue_cutoff_edges', API, ".lte('due', horizonIso);", ".lt('due', horizonIso);"),
    Mutation('Q05', 'queue_edges', API, 'now.toUtc().add(horizon)', 'now.toUtc().add(const Duration(hours: 24))'),
    Mutation('Q06', 'queue_edges', API, 'now: now,\n          deckId: deckId,', 'now: _localNow(),\n          deckId: deckId,'),
    Mutation('Q07', 'queue_edges', API, 'newOrderDaySeed(now, deckId));\n    }\n\n    final ordinary', 'newOrderDaySeed(_localNow(), deckId));\n    }\n\n    final ordinary'),
    Mutation('Q08', 'queue_edges', API, 'now.toUtc().add(horizon)', '_localNow().toUtc().add(horizon)'),
    Mutation('Q09', 'queue_edges', API, '(newLimit - introducedToday)', '(newLimit + introducedToday)'),
    Mutation('Q10', 'queue_edges', API, 'todayCardIds.difference(seenBefore).length', 'todayCardIds.intersection(seenBefore).length'),
    Mutation('Q11', 'queue_edges', API, ".lt('rating_at', startIso);", ".lte('rating_at', startIso);"),
    Mutation('Q12', 'queue_edges', API, ".gte('rating_at', startIso)", ".gt('rating_at', startIso)"),
    Mutation('Q13', 'queue_edges', API, ".lt('rating_at', endIso);", ".lte('rating_at', endIso);"),
    Mutation('Q14', 'queue_edges', API, 'final newSlots = limit - ahead.length;', 'final newSlots = limit;'),
    Mutation('Q15', 'queue_edges', API, 'newOrderDaySeed(now, deckId));\n    }\n    return [...ahead', 'newOrderDaySeed(_localNow(), deckId));\n    }\n    return [...ahead'),
    Mutation('C01', 'controller_edges', CONTROLLER, '!due.isAfter(clock().toUtc())', 'due.isBefore(clock().toUtc())'),
    Mutation('C02', 'controller_edges', CONTROLLER, '_preview = engine.preview(card, now: _previewAt);', '_preview = engine.preview(card);'),
    Mutation('C03', 'controller_edges', CONTROLLER, 'final outcome = engine.review(card, rating, now: reviewedAt);', 'final outcome = engine.review(card, rating);'),
    Mutation('C04', 'controller_edges', CONTROLLER, 'if (_previewForCardId != card.id) {', 'if (true) {'),
    Mutation('C05', 'controller_edges', CONTROLLER, 'if (review.at.isBefore(since)) continue;', 'if (!review.at.isAfter(since)) continue;'),
    Mutation('S01', 'schedule', ENGINE, 'reps: c.reps + 1,', 'reps: c.reps,'),
    Mutation('S02', 'schedule', ENGINE, 'lapses: c.lapses + (lapsed ? 1 : 0),', 'lapses: c.lapses + (lapsed ? 0 : 0),'),
    Mutation('S03', 'schedule', ENGINE, 'c.state == 2 || c.state == 3', 'c.state == 2'),
    Mutation('S04', 'schedule', ENGINE, 'rating == Rating.again && wasReviewish', 'rating != Rating.again && wasReviewish'),
    Mutation('S05', 'schedule', ENGINE, 'gap >= steps[i]', 'gap > steps[i]'),
    Mutation('S06', 'schedule', ENGINE, 'if (due == null || lastReview == null) return 0;', 'if (due == null || lastReview == null) return 1;'),
    Mutation('S07', 'schedule', ENGINE, '3 => State.relearning,', '3 => State.review,'),
    Mutation('S08', 'schedule', ENGINE, 'if (c.isNew || (c.stability ?? 0) <= 0)', 'if (c.isNew && (c.stability ?? 0) <= 0)'),
    Mutation('S09', 'schedule', ENGINE, '_configure(parameters: _parameters, desiredRetention: desiredRetention);', '_configure(parameters: defaultParameters, desiredRetention: desiredRetention);'),
    Mutation('S10', 'schedule', ENGINE, 'currentDateTime: when,', 'currentDateTime: when.add(const Duration(days: 1)),'),
    Mutation('O01', 'outbox', STORE, "'delivery_attempted': entry['delivery_attempted'] ?? false,", "'delivery_attempted': entry['delivery_attempted'] ?? true,"),
    Mutation('O02', 'outbox', STORE, "e['client_id'] == clientId && e['delivery_attempted'] == false", "e['client_id'] == clientId && e['delivery_attempted'] != true"),
    Mutation('O03', 'outbox', STORE, 'Object key(Object id) => id is int ? id.toString() : id;', 'Object key(Object id) => id;'),
    Mutation('O04', 'outbox', STORE, 'if (!ambiguous.contains(entry.key)) entry.value,', 'if (true) entry.value,'),
    Mutation('O05', 'outbox', STORE, 'if (left.length != right.length) return false;', 'if (false) return false;'),
    Mutation('O06', 'outbox', STORE, 'id is int || (id is String && id.isNotEmpty);', 'id is int || id is String;'),
    Mutation('O07', 'outbox', STORE, 'timestamp.day != int.parse(match[3]!) ||', 'false ||'),
    Mutation('O08', 'outbox', STORE, 'device.trim().isEmpty ||', 'device.isEmpty ||'),
    Mutation('O09', 'outbox', STORE, 'cardId <= 0 ||', 'cardId < 0 ||'),
    Mutation('O10', 'outbox', STORE, 'if (id != null && wanted.contains(id))', 'if (id != null)'),
    Mutation('M01', 'migration', STORE, 'ownerClaim == scope && prefs.getBool(migrationKey) != true', 'prefs.getBool(migrationKey) != true'),
    Mutation('M02', 'migration', STORE, 'legacy != null && prefs.getString(scoped) == null', 'legacy != null'),
    Mutation('M03', 'migration', STORE, 'ownerClaim == scope && prefs.getBool(migrationKey) != true', 'ownerClaim == scope'),
    Mutation('M04', 'migration', STORE, 'if (ownerId.trim().isEmpty)', 'if (ownerId.isEmpty)'),
    Mutation('R01', 'replay', REPLAY, 'if (flag is bool) return flag;', 'if (flag is bool) return !flag;'),
    Mutation('R02', 'replay', REPLAY, "'reps': (server.reps ?? 0) + 1,", "'reps': (server.reps ?? 0) + 0,"),
    Mutation('R03', 'replay', REPLAY, 'if (server.lastReviewUnreadable) return const {};', 'if (server.lastReviewUnreadable) return values;'),
    Mutation('R04', 'replay', REPLAY, 'serverAt.isAtSameMomentAs(eventAt)', 'false'),
    Mutation('R05', 'replay', REPLAY, 'eventAt.isAfter(serverAt)', 'eventAt.isBefore(serverAt)'),
    Mutation('R06', 'replay', REPLAY, 'expectedReps: server.reps,', 'expectedReps: server.reps ?? 0,'),
    Mutation('R07', 'replay', REPLAY, 'attempt < maxAttempts;', 'attempt <= maxAttempts;'),
    Mutation('R08', 'replay', REPLAY, 'if (updated > 0) return;', 'if (updated >= 0) return;'),
]


@contextmanager
def repository_lock(root):
    directory = root / '.dart_tool/mutation-sweep'
    directory.mkdir(parents=True, exist_ok=True)
    # Keep this inode: unlinking it could give concurrent owners different locks.
    with (directory / 'repository.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('Another mutation sweep owns this repository; '
                             'no tests or mutations started.') from None
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


@contextmanager
def planted(root, mutation):
    """Plant one mutant while the caller owns the repository sweep lock."""
    path = root / mutation.path
    original = path.read_bytes()
    source = original.decode('utf-8')
    if source.count(mutation.before) != 1:
        raise ValueError(f'{mutation.id}: expected exactly one source match')
    try:
        path.write_text(source.replace(mutation.before, mutation.after, 1), encoding='utf-8')
        yield
    finally:
        path.write_bytes(original)


def run(command, log, timeout, cwd=ROOT):
    started = time.monotonic()
    with log.open('w', encoding='utf-8') as output:
        process = subprocess.Popen(command, cwd=cwd, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return {'status': 'timeout', 'seconds': round(time.monotonic() - started, 2)}
        finally:
            # Also clean up children if interrupted or the parent exited early.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
    output = log.read_text(encoding='utf-8')
    status = 'survived' if code == 0 else 'invalid'
    # A compile/tooling failure is never counted as a test kill.
    if (code != 0 and '[E]' in output and 'Expected:' in output
            and 'Actual:' in output and 'Failed to load' not in output
            and 'Compilation failed' not in output):
        status = 'killed'
    return {'status': status, 'exit_code': code,
            'seconds': round(time.monotonic() - started, 2)}


def interrupt(_signum, _frame):
    # Turn termination into normal stack unwinding, restoring any planted file.
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', required=True, choices=['before', 'after'])
    parser.add_argument('--ids', nargs='+', choices=[m.id for m in MUTATIONS])
    parser.add_argument('--timeout', type=int, default=180)
    parser.add_argument('--batch', choices=['replay'])
    args = parser.parse_args()
    with repository_lock(ROOT):
        run_sweep(args)


def run_sweep(args):
    """Run the baseline and all probes under main's repository ownership."""
    output = ROOT / '.dart_tool/mutation-sweep' / args.phase
    if args.batch:
        output /= args.batch
    output.mkdir(parents=True, exist_ok=True)
    mutations = [m for m in MUTATIONS if args.ids is None or m.id in args.ids]
    command = ['./tool/flutterw', 'test', '--no-pub', '--concurrency=1',
               '--reporter=expanded', '--exclude-tags', 'apple-mobile']
    def tests(group):
        regressions = [REGRESSIONS] if args.phase == 'after' else []
        if args.phase == 'after' and group.endswith('_edges'):
            regressions.append(SCHEDULING_REGRESSIONS)
        return list(dict.fromkeys(TESTS[group] + regressions))
    baseline_tests = sorted({p for m in mutations for p in tests(m.group)})
    baseline = run(command + baseline_tests, output / 'baseline.log', args.timeout)
    if baseline['status'] != 'survived':
        raise SystemExit(f'Baseline did not pass: {baseline}; see {output}/baseline.log')
    results = []
    try:
        for mutation in mutations:
            with planted(ROOT, mutation):
                result = run(command + tests(mutation.group),
                             output / f'{mutation.id}.log', args.timeout)
            result.update(id=mutation.id, command=command + tests(mutation.group))
            results.append(result)
            print(json.dumps(result), flush=True)
            if result['status'] in ('invalid', 'timeout'):
                raise SystemExit(f'Unresolved {mutation.id}: inspect its log before continuing')
    finally:
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupt)
    main()
