// No backend: scripted reads and CAS outcomes exercise the production merge.
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/features/review/data/review_replay.dart';

final _at = DateTime.utc(2026, 10, 23, 12);

Map<String, dynamic> _event() => {
  'card_id': 701,
  'last_review': _at.toIso8601String(),
  'due': _at.add(const Duration(days: 8)).toIso8601String(),
  'stability': 8.0,
  'difficulty': 5.0,
  'state': 2,
  'rating': 3,
  'lapsed': false,
  'reps': 999, // Stale absolute counters must never become authoritative.
  'lapses': 999,
};

class _Gateway implements ReviewReplayGateway {
  _Gateway(this.read, {this.write});

  final Future<CardSyncState?> Function() read;
  final Future<int> Function()? write;
  int reads = 0;
  final versions = <int?>[];
  final patches = <Map<String, dynamic>>[];

  @override
  Future<CardSyncState?> readCardState(int cardId) {
    expect(cardId, 701);
    reads++;
    return read();
  }

  @override
  Future<int> updateCardWhereReps(
    int cardId, {
    required int? expectedReps,
    required Map<String, dynamic> values,
  }) async {
    expect(cardId, 701);
    versions.add(expectedReps);
    patches.add(Map.of(values));
    return write == null ? 1 : await write!();
  }
}

void main() {
  group('fallback replay ordering', () {
    for (final offset in [-1, 0, 1]) {
      test('orders reviews $offset microseconds from the server instant', () {
        final event = _event()
          ..['last_review'] = _at
              .add(Duration(microseconds: offset))
              .toIso8601String();
        final patch = mergeReviewIntoCard(
          server: CardSyncState(reps: 7, lapses: 2, lastReview: _at),
          entry: event,
        );
        if (offset == 0) {
          // A retry after a partial apply must not count the same rep twice.
          expect(patch, isEmpty);
        } else if (offset < 0) {
          expect(patch, {'reps': 8, 'lapses': 2, 'cloud_seen': true});
        } else {
          expect(patch, {
            for (final key in [
              'stability',
              'difficulty',
              'due',
              'state',
              'last_review',
            ])
              key: event[key],
            'reps': 8,
            'lapses': 2,
            'cloud_seen': true,
          });
        }
      });
    }

    test('different UTC offsets identify the same already-applied instant', () {
      final server = CardSyncState.fromRow({
        'reps': 7,
        'lapses': 2,
        'last_review': '2026-10-23T09:00:00-03:00',
      });
      expect(server.lastReview, _at);
      expect(server.lastReview!.isUtc, isTrue);
      expect(mergeReviewIntoCard(server: server, entry: _event()), isEmpty);
    });

    for (final raw in <Object>['unreadable', 42, false]) {
      test('unreadable server timestamp ($raw) prevents any CAS', () async {
        final gateway = _Gateway(
          () async => CardSyncState.fromRow({
            'reps': 7,
            'lapses': 2,
            'last_review': raw,
          }),
        );
        await applyMergedReview(gateway, _event());
        expect(gateway.reads, 1);
        expect(gateway.patches, isEmpty);
      });
    }

    for (final raw in <String?>[null, 'unreadable']) {
      test(
        'missing or invalid event timestamp ($raw) preserves server schedule',
        () {
          final patch = mergeReviewIntoCard(
            server: CardSyncState(reps: 7, lapses: 2, lastReview: _at),
            entry: _event()..['last_review'] = raw,
          );
          expect(patch, {'reps': 8, 'lapses': 2, 'cloud_seen': true});
        },
      );
    }

    test('explicit lapse flag overrides legacy transition inference', () {
      for (final flag in [true, false]) {
        final patch = mergeReviewIntoCard(
          server: const CardSyncState(
            reps: null,
            lapses: null,
            lastReview: null,
          ),
          entry: _event()
            ..['lapsed'] = flag
            ..['rating'] = flag ? 3 : 1
            ..['state'] = flag ? 2 : 3,
        );
        expect(patch['reps'], 1);
        expect(patch['lapses'], flag ? 1 : 0);
      }
    });

    test('legacy entries count a lapse only for Again into relearning', () {
      for (final flag in <Object?>[null, 'legacy']) {
        for (final rating in [1, 2, 3, 4]) {
          for (final state in [1, 2, 3]) {
            final patch = mergeReviewIntoCard(
              server: const CardSyncState(reps: 7, lapses: 2, lastReview: null),
              entry: _event()
                ..['lapsed'] = flag
                ..['rating'] = rating
                ..['state'] = state,
            );
            expect(
              patch['lapses'],
              rating == 1 && state == 3 ? 3 : 2,
              reason: 'flag=$flag rating=$rating state=$state',
            );
          }
        }
      }
    });
  });

  group('fallback compare-and-swap lifecycle', () {
    test(
      'the final allowed attempt re-reads and keeps a newer schedule',
      () async {
        var version = 7;
        final gateway = _Gateway(
          () async => CardSyncState(
            reps: version,
            lapses: version - 5,
            lastReview: version == 7
                ? null
                : _at.add(const Duration(seconds: 1)),
          ),
          write: () async => ++version == 11 ? 1 : 0,
        );
        await applyMergedReview(gateway, _event());
        expect(gateway.reads, 4);
        expect(gateway.versions, [7, 8, 9, 10]);
        expect(gateway.patches.first['due'], _event()['due']);
        expect(gateway.patches.skip(1), [
          {'reps': 9, 'lapses': 3, 'cloud_seen': true},
          {'reps': 10, 'lapses': 4, 'cloud_seen': true},
          {'reps': 11, 'lapses': 5, 'cloud_seen': true},
        ]);
      },
    );

    test(
      'a card deleted after a lost CAS completes without another write',
      () async {
        var deleted = false;
        final gateway = _Gateway(
          () async => deleted
              ? null
              : const CardSyncState(reps: 7, lapses: 2, lastReview: null),
          write: () async {
            deleted = true;
            return 0;
          },
        );
        await applyMergedReview(gateway, _event());
        expect(gateway.reads, 2);
        expect(gateway.versions, [7]);
      },
    );

    test('an already deleted card completes without a write', () async {
      final gateway = _Gateway(() async => null);
      await applyMergedReview(gateway, _event());
      expect(gateway.reads, 1);
      expect(gateway.patches, isEmpty);
    });

    test('a competing partial apply on retry is not counted again', () async {
      DateTime? serverAt;
      final gateway = _Gateway(
        () async => CardSyncState(reps: 7, lapses: 2, lastReview: serverAt),
        write: () async {
          serverAt = _at;
          return 0;
        },
      );
      await applyMergedReview(gateway, _event());
      expect(gateway.reads, 2);
      expect(gateway.versions, [7]);
    });

    for (final failRead in [true, false]) {
      test(
        '${failRead ? 'read' : 'write'} failure propagates without CAS retry',
        () async {
          final error = StateError('synthetic transport failure');
          final gateway = _Gateway(() async {
            if (failRead) throw error;
            return const CardSyncState(reps: 7, lapses: 2, lastReview: null);
          }, write: () async => throw error);
          await expectLater(
            applyMergedReview(gateway, _event()),
            throwsA(same(error)),
          );
          expect(gateway.reads, 1);
          expect(gateway.patches, hasLength(failRead ? 0 : 1));
        },
      );
    }
  });
}
