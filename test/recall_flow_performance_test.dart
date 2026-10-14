import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../tool/fixtures/synthetic_recall_flow.dart';

const _sourceCommit = 'ccd1a245ace9cfce1635ba57ba6a9c44e892a9b1';
const _waitLimit = Duration(minutes: 10);

class _GatedNativePreferences extends InMemorySharedPreferencesStore {
  _GatedNativePreferences() : super.empty();

  Completer<void>? nextOutboxWriteEntered;
  Completer<void>? nextOutboxWriteRelease;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.contains('recall_outbox_v1')) {
      final entered = nextOutboxWriteEntered;
      final release = nextOutboxWriteRelease;
      nextOutboxWriteEntered = null;
      nextOutboxWriteRelease = null;
      if (entered != null && release != null) {
        entered.complete();
        await release.future;
      }
    }
    return super.setValue(valueType, key, value);
  }
}

Future<
  ({
    SyntheticRecallFlow flow,
    _GatedNativePreferences native,
    SharedPreferencesStorePlatform previous,
  })
>
_testFlow({
  required int cardCount,
  required int seededOutbox,
  required bool warmCache,
}) async {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _GatedNativePreferences();
  SharedPreferencesStorePlatform.instance = native;
  try {
    final flow = await SyntheticRecallFlow.create(
      cardCount: cardCount,
      seededOutbox: seededOutbox,
      warmCache: warmCache,
    );
    return (flow: flow, native: native, previous: previous);
  } catch (_) {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
    rethrow;
  }
}

Future<void> _closeTestFlow(
  ({
    SyntheticRecallFlow flow,
    _GatedNativePreferences native,
    SharedPreferencesStorePlatform previous,
  })
  session,
) async {
  try {
    await session.flow.close();
  } finally {
    SharedPreferencesStorePlatform.instance = session.previous;
    SharedPreferences.resetStatic();
  }
}

class _Case {
  const _Case(this.name, this.cards, this.outbox, this.warmCache, this.repeats);

  final String name;
  final int cards;
  final int outbox;
  final bool warmCache;
  final int repeats;
}

const _cases = [
  _Case('cold_20', 20, 0, false, 2),
  _Case('warm_20', 20, 0, true, 2),
  _Case('warm_600_pending_20', 600, 20, true, 1),
  _Case('warm_2500_pending_2500', 2500, 2500, true, 1),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rating waits for the real outbox append acknowledgement',
    () async {
      final session = await _testFlow(
        cardCount: 20,
        seededOutbox: 0,
        warmCache: false,
      );
      final flow = session.flow;
      addTearDown(() => _closeTestFlow(session));
      await flow.load().timeout(_waitLimit);
      expect(flow.controller.state.current?.id, 1);
      flow.controller.flip();

      final entered = Completer<void>();
      final release = Completer<void>();
      session.native.nextOutboxWriteEntered = entered;
      session.native.nextOutboxWriteRelease = release;
      final rating = flow.controller.rate(Rating.good);
      try {
        await entered.future.timeout(_waitLimit);
        expect(flow.controller.state.index, 0);
        expect(flow.controller.state.current?.id, 1);
        expect(flow.controller.rateInFlight, isTrue);
      } finally {
        release.complete();
      }
      await rating.timeout(_waitLimit);
      expect(flow.controller.state.index, 1);
      expect(flow.controller.state.current?.id, 2);
      final pending = await flow.store.outbox().timeout(_waitLimit);
      expect(pending, hasLength(1));
      expect(pending.single['card_id'], 1);
      expect(
        pending.single['client_id'],
        isA<String>().having(
          (value) => value.isNotEmpty,
          'nonempty durable event ID',
          true,
        ),
      );
      await flow.controller.syncPending().timeout(_waitLimit);
      expect(await flow.store.outbox(), hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );

  test(
    'synthetic source-flow timings and integrity',
    () async {
      for (final spec in _cases) {
        for (var repetition = 1; repetition <= spec.repeats; repetition++) {
          final session = await _testFlow(
            cardCount: spec.cards,
            seededOutbox: spec.outbox,
            warmCache: spec.warmCache,
          );
          final flow = session.flow;
          try {
            final totalWatch = Stopwatch()..start();
            int? firstCardUs;
            flow.controller.addListener(() {
              if (firstCardUs == null &&
                  flow.controller.state.current != null) {
                firstCardUs = totalWatch.elapsedMicroseconds;
              }
            });

            final loadTrace = developer.TimelineTask()
              ..start(
                'recall.synthetic.load',
                arguments: {
                  'case': spec.name,
                  'cards': spec.cards,
                  'outbox': spec.outbox,
                },
              );
            final loadStartRequests = flow.httpFixture.totalRequests;
            final loadWatch = Stopwatch()..start();
            try {
              await flow.load().timeout(_waitLimit);
            } finally {
              loadWatch.stop();
              loadTrace.finish();
            }
            final loadRequests =
                flow.httpFixture.totalRequests - loadStartRequests;
            expect(flow.controller.state.loading, isFalse);
            expect(flow.controller.state.queue, hasLength(spec.cards));
            expect(flow.controller.state.current?.id, 1);
            expect(
              flow.httpFixture.counts['cards_due'],
              (spec.cards + 499) ~/ 500 + 1,
            );
            expect(flow.httpFixture.counts['cards_new'], 1);
            expect(flow.httpFixture.counts['cards_revalidation'], 1);
            if (spec.warmCache) {
              expect(firstCardUs, isNotNull);
              expect(
                firstCardUs!,
                lessThanOrEqualTo(loadWatch.elapsedMicroseconds),
              );
            }

            flow.controller.flip();
            expect(flow.controller.state.showBack, isTrue);
            final rateStartRequests = flow.httpFixture.totalRequests;
            final rateTrace = developer.TimelineTask()
              ..start('recall.synthetic.rate_to_next');
            final rateWatch = Stopwatch()..start();
            try {
              await flow.controller.rate(Rating.good).timeout(_waitLimit);
            } finally {
              rateWatch.stop();
              rateTrace.finish();
            }
            final rateRequests =
                flow.httpFixture.totalRequests - rateStartRequests;
            expect(flow.controller.state.current?.id, 2);
            expect(flow.controller.state.reviewedThisSession, 1);
            final pendingAfterRate = await flow.store.outbox().timeout(
              _waitLimit,
            );
            expect(pendingAfterRate, hasLength(spec.outbox + 1));
            expect(pendingAfterRate.last['card_id'], 1);
            expect(pendingAfterRate.last['client_id'], isA<String>());
            expect(flow.store.lastEnqueueAckUs, greaterThanOrEqualTo(0));

            // Deliberately separate delivery from next-card latency. The real
            // controller drains the real local outbox through inherited
            // RecallApi.applyReview and the .invalid fake HTTP transport.
            flow.httpFixture.deliverReviews = true;
            final drainStartRequests = flow.httpFixture.totalRequests;
            final drainTrace = developer.TimelineTask()
              ..start('recall.synthetic.network_drain');
            final drainWatch = Stopwatch()..start();
            try {
              await flow.controller.syncPending().timeout(_waitLimit);
            } finally {
              drainWatch.stop();
              drainTrace.finish();
            }
            final drainRequests =
                flow.httpFixture.totalRequests - drainStartRequests;
            final pendingAfterDrain = await flow.store.outbox().timeout(
              _waitLimit,
            );
            expect(pendingAfterDrain, isEmpty);
            expect(
              flow.httpFixture.counts['apply_review'],
              greaterThanOrEqualTo(spec.outbox + 1),
            );

            // Closed, value-free schema: no card text, owner id, URLs, tokens or
            // request bodies enter benchmark output.
            final record = <String, Object?>{
              'schema': 'recall-synthetic-flow-performance/v1',
              'source_commit': _sourceCommit,
              'source_phase': 'controller_store_api_fake_http',
              'case': spec.name,
              'repetition': repetition,
              'fixture': {
                'cards': spec.cards,
                'seeded_outbox': spec.outbox,
                'warm_cache': spec.warmCache,
              },
              'timing_us': {
                'cache_first_card': spec.warmCache ? firstCardUs : null,
                'fetch_final': loadWatch.elapsedMicroseconds,
                'api_fetch_queue': flow.api.fetchQueueUs,
                'rate_to_next': rateWatch.elapsedMicroseconds,
                'rate_native_ack': flow.store.lastEnqueueAckUs,
                'network_drain': drainWatch.elapsedMicroseconds,
                'api_apply_review': flow.api.applyReviewUs,
                'fixture_http_handler': flow.httpFixture.handlerUs,
              },
              'requests': {
                'load': loadRequests,
                'rate': rateRequests,
                'drain': drainRequests,
                'by_kind': flow.httpFixture.snapshotCounts(),
              },
              'integrity': {
                'pending_after_rate': pendingAfterRate.length,
                'pending_after_drain': pendingAfterDrain.length,
                'rated_card_id': 1,
                'next_card_id': 2,
              },
            };
            // ignore: avoid_print
            print(jsonEncode(record));
          } finally {
            await _closeTestFlow(session);
          }
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 40)),
  );
}
