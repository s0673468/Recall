// Run explicitly with --dart-define=RECALL_SPEED_BENCHMARK=true.
// Synthetic in-process measurements: no HTTP, device data, or native disk.
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/features/review/application/backlog_catch_up.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'support/recall_test_harness.dart';

final _now = DateTime.utc(2026, 10, 22, 12);

List<ReviewCard> _cards(int size) => [
  for (var i = 0; i < size; i++)
    testCard(
      id: i + 1,
      deckId: i.isEven ? 1 : 2,
      state: i % 10 == 0 ? 0 : 2,
      stability: 1 + (i * 37 % 100).toDouble(),
      difficulty: 5,
      due: _now.subtract(Duration(days: i % 7 + 1)),
      lastReview: _now.subtract(Duration(days: i * 17 % 90 + 1)),
    ),
];

Future<int> _time(Future<void> Function() action) async {
  final watch = Stopwatch()..start();
  await action();
  return watch.elapsedMicroseconds;
}

// Frozen full-sort kernel from the pre-fix presented queue path. Keep this
// independent of orderDue so future improvements do not move the baseline.
List<ReviewCard> _legacySelect(List<ReviewCard> cards, FsrsEngine engine) {
  final due = [
    for (final card in cards)
      if (!card.isNew) card,
  ];
  final ranked = [
    for (var index = 0; index < due.length; index++)
      (
        card: due[index],
        index: index,
        retrievability: engine.retrievability(due[index], now: _now),
      ),
  ];
  ranked.sort((a, b) {
    final order = a.retrievability.compareTo(b.retrievability);
    return order == 0 ? a.index.compareTo(b.index) : order;
  });
  final ordered = [for (final item in ranked) item.card];
  return ordered.take(20).toList();
}

int _counterTicks(List<ReviewCard> cards, {required bool legacy}) {
  var state = const ReviewState().copyWith(queue: cards);
  final watch = Stopwatch()..start();
  var checksum = 0;
  for (var i = 0; i < 1000; i++) {
    state = state.copyWith(index: (i * 17) % cards.length);
    checksum += legacy
        ? state.queue.skip(state.index).where((c) => !c.isNew).length +
              state.queue.skip(state.index).where((c) => c.isNew).length
        : state.dueRemaining + state.newRemaining;
  }
  watch.stop();
  expect(
    checksum,
    List.generate(
      1000,
      (i) => cards.length - (i * 17) % cards.length,
    ).fold<int>(0, (sum, count) => sum + count),
  );
  return watch.elapsedMicroseconds;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final size in [2000, 20000]) {
    test('synthetic review speed $size', () async {
      final cards = _cards(size);
      final samples = <String, List<int>>{};
      void record(String name, int micros) =>
          samples.putIfAbsent(name, () => []).add(micros);

      // One warm-up, followed by seven identical workloads. Report medians.
      for (var run = 0; run < 8; run++) {
        SharedPreferences.setMockInitialValues({});
        final store = LocalReviewStore();
        const decks = [
          DeckRow(deckId: 1, name: 'Synthetic A'),
          DeckRow(deckId: 2, name: 'Synthetic B'),
        ];
        await store.saveSnapshot(decks: decks, queue: cards);
        final api = FakeRecallApi(cards, decks: decks)
          ..beforeQueue = () async => throw StateError('synthetic offline');
        var controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
          clock: () => _now,
        );
        final times = <String, int>{};
        final firstCard = Stopwatch()..start();
        void observe() {
          if (controller.state.current != null) firstCard.stop();
        }

        controller.addListener(observe);
        await controller.load();
        controller.removeListener(observe);
        expect(controller.state.offline, isTrue);
        expect(controller.state.queue, hasLength(size));
        times['cached_first_card'] = firstCard.elapsedMicroseconds;

        // Mirrors selectors on flip/grade/sync ticks, including forward and
        // backward index changes (Undo). Queue replacement is outside timing.
        // Pair old/new kernels in one process and alternate their order to
        // reduce VM warm-up and host load bias. Index construction is included
        // in the first timed counter read, while the queue copy is excluded.
        final engine = FsrsEngine();
        final kernels = <String, Future<int> Function()>{
          'counter_scan_1000_ticks': () async =>
              _counterTicks(cards, legacy: true),
          'counter_index_1000_ticks': () async =>
              _counterTicks(cards, legacy: false),
          'full_sort': () => _time(() async {
            expect(_legacySelect(cards, engine), hasLength(20));
          }),
          'bounded_select': () => _time(() async {
            expect(
              BacklogCatchUp.takeDueForToday(
                cards,
                engine,
                now: _now,
                completedToday: 0,
              ),
              hasLength(20),
            );
          }),
        };
        final names = run.isEven
            ? kernels.keys
            : kernels.keys.toList().reversed;
        for (final name in names) {
          times[name] = await kernels[name]!();
        }
        expect(
          BacklogCatchUp.takeDueForToday(
            cards,
            engine,
            now: _now,
            completedToday: 0,
          ),
          _legacySelect(cards, engine),
        );

        times['grade'] = await _time(() async {
          controller.flip();
          await controller.rate(Rating.good);
        });
        expect(controller.state.index, 1);
        times['undo'] = await _time(controller.undo);
        expect(controller.state.index, 0);
        expect(await store.outbox(), isEmpty);

        times['catch_up_select'] = await _time(controller.startCatchUp);
        expect(controller.state.queue, hasLength(20));

        // An active episode is persisted. Restart from its full cached source
        // to measure ranking on the cold-start-to-first-card path as well.
        controller.dispose();
        controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
          clock: () => _now,
        );
        final activeFirstCard = Stopwatch()..start();
        void observeActive() {
          if (controller.state.current != null) activeFirstCard.stop();
        }

        controller.addListener(observeActive);
        await controller.load();
        controller.removeListener(observeActive);
        expect(controller.state.queue, hasLength(20));
        times['active_cached_first_card'] = activeFirstCard.elapsedMicroseconds;
        await controller.showAll();

        // Sync a fixed 20-review session, independently of collection size.
        for (var i = 0; i < 20; i++) {
          controller.flip();
          await controller.rate(Rating.good);
        }
        times['sync_20_reviews'] = await _time(controller.syncPending);
        expect(await store.outbox(), isEmpty);
        expect(api.applied, hasLength(20));

        api.beforeQueue = null;
        times['deck_switch'] = await _time(() => controller.selectDeck(2));
        expect(controller.state.queue.every((c) => c.deckId == 2), isTrue);
        // Join disposable snapshot writes before replacing mock storage.
        await store.outbox();
        controller.dispose();
        if (run > 0) times.forEach(record);
      }
      for (final entry in samples.entries) {
        entry.value.sort();
        // ignore: avoid_print
        print(
          'speed_hunt cards=$size ${entry.key}_median_us=${entry.value[3]}',
        );
      }
    }, skip: !const bool.fromEnvironment('RECALL_SPEED_BENCHMARK'));
  }
}
