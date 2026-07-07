import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';

void main() {
  group('RecallPrefs parsing', () {
    test('empty / non-map → historical defaults', () {
      const d = RecallPrefs();
      expect(d.newLimitDefault, 20);
      expect(d.desiredRetention, 0.9);
      expect(d.newOrder, NewOrder.oldestFirst);
      expect(RecallPrefs.fromJson(null), d);
      expect(RecallPrefs.fromJson('nope'), d);
    });

    test('round-trips through toJson/fromJson', () {
      const prefs = RecallPrefs(
        newLimitDefault: 35,
        desiredRetention: 0.88,
        newOrder: NewOrder.random,
        perDeck: {7: 5, 9: 0},
      );
      expect(RecallPrefs.fromJson(prefs.toJson()), prefs);
    });

    test('ignores unknown keys and clamps retention', () {
      final p = RecallPrefs.fromJson({
        'new_limit_default': 40,
        'desired_retention': 0.5, // below floor → clamped to 0.70
        'new_order': 'newest_first',
        'surprise': 'ignored',
        'per_deck': {'12': {'new_limit': 3}},
      });
      expect(p.newLimitDefault, 40);
      expect(p.desiredRetention, 0.70);
      expect(p.newOrder, NewOrder.newestFirst);
      expect(p.perDeck[12], 3);
    });

    test('tolerates a bare numeric per-deck override', () {
      final p = RecallPrefs.fromJson({
        'per_deck': {'5': 8},
      });
      expect(p.perDeck[5], 8);
    });
  });

  group('newLimitForDeck', () {
    const prefs = RecallPrefs(newLimitDefault: 20, perDeck: {7: 5});
    test('deck override beats the default', () {
      expect(prefs.newLimitForDeck(7), 5);
    });
    test('unknown deck and all-decks fall back to the default', () {
      expect(prefs.newLimitForDeck(99), 20);
      expect(prefs.newLimitForDeck(null), 20);
    });
    test('withDeckOverride sets and clears', () {
      final set = prefs.withDeckOverride(9, 3);
      expect(set.perDeck[9], 3);
      final cleared = set.withDeckOverride(9, null);
      expect(cleared.perDeck.containsKey(9), isFalse);
    });
  });

  group('sameQueueShape', () {
    test('retention-only change keeps the queue shape', () {
      const a = RecallPrefs(desiredRetention: 0.9);
      final b = a.copyWith(desiredRetention: 0.85);
      expect(a.sameQueueShape(b), isTrue);
    });
    test('limit/order/per-deck changes break the queue shape', () {
      const a = RecallPrefs();
      expect(a.sameQueueShape(a.copyWith(newLimitDefault: 10)), isFalse);
      expect(a.sameQueueShape(a.copyWith(newOrder: NewOrder.random)), isFalse);
      expect(a.sameQueueShape(a.withDeckOverride(1, 5)), isFalse);
    });
  });

  group('seededShuffle', () {
    test('is stable for the same seed and permutes the list', () {
      final items = List<int>.generate(20, (i) => i);
      final a = seededShuffle(items, 12345);
      final b = seededShuffle(items, 12345);
      expect(a, b); // deterministic
      expect(a..sort(), items); // same multiset
    });

    test('different seeds generally differ', () {
      final items = List<int>.generate(20, (i) => i);
      expect(seededShuffle(items, 1), isNot(seededShuffle(items, 2)));
    });
  });

  group('newOrderDaySeed', () {
    test('same day + deck → same seed; different day/deck → different', () {
      final d1 = DateTime(2026, 7, 7);
      final d2 = DateTime(2026, 7, 8);
      expect(newOrderDaySeed(d1, 3), newOrderDaySeed(d1, 3));
      expect(newOrderDaySeed(d1, 3), isNot(newOrderDaySeed(d2, 3)));
      expect(newOrderDaySeed(d1, 3), isNot(newOrderDaySeed(d1, 4)));
    });
  });

  group('retentionWorkloadMultiplier', () {
    test('is ×1.0 at the 0.9 baseline and monotonic', () {
      expect(retentionWorkloadMultiplier(0.9), closeTo(1.0, 1e-9));
      expect(
        retentionWorkloadMultiplier(0.97),
        greaterThan(retentionWorkloadMultiplier(0.9)),
      );
      expect(
        retentionWorkloadMultiplier(0.8),
        lessThan(retentionWorkloadMultiplier(0.9)),
      );
    });
  });
}
