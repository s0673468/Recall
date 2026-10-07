import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:health_anki_flutter/core/background/browser_foreground_sync_coordinator.dart';
import 'package:health_anki_flutter/core/background/browser_sync_platform.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/domain/local_day.dart';

// Real production logic with synthetic platform/storage adapters. These tests
// do not establish browser persistence, SQL parity, or generated-schedule passes.
class _Browser implements BrowserSyncPlatform {
  @override
  bool get supported => true;
  @override
  bool visible = true;
  @override
  bool online = true;
  void Function()? wake;
  @override
  void start(void Function() onWake) => wake = onWake;
  @override
  void dispose() => wake = null;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('synthetic flag domain separates reporting from hiding', () {
    expect(ReviewController.hideReasons, {'dislike', 'delete'});
    expect(ReviewController.flagReasons, {
      'wrong', 'confusing', 'too_long', 'duplicate', 'dislike', 'delete',
    });
    expect(ReviewController.flagReasons.contains('unknown'), isFalse);
    expect(ReviewController.flagReasons.contains(''), isFalse);
  });

  test('old-owner flag acknowledgement preserves new owner and tail', () async {
    final store = LocalReviewStore();
    await store.activateOwner('synthetic-owner-a');
    final ownerA = store.activeOwnerScope!;
    await store.enqueueFlag({'client_id': 'a-delivered', 'reason': 'delete'});
    await store.enqueueFlag({'client_id': 'a-tail', 'reason': 'wrong'});
    await store.addHiddenCard(1001);
    await store.activateOwner('synthetic-owner-b');
    await store.enqueueFlag({'client_id': 'b-pending', 'reason': 'dislike'});
    await store.addHiddenCard(1002);
    expect(await store.removeFirstFlag(1, ownerScope: ownerA), 1);
    expect((await store.flagOutbox()).single['client_id'], 'b-pending');
    expect(await store.hiddenCardIds(), {1002});
    await store.activateOwner('synthetic-owner-a');
    expect((await store.flagOutbox()).single['client_id'], 'a-tail');
    expect(await store.hiddenCardIds(), {1001});
    expect(await store.removeFlagEntry('a-delivered'), isFalse);
    expect(await store.removeFlagEntry('a-tail'), isTrue);
    expect(await store.flagOutbox(), isEmpty);
  });

  test('queued flag removal never drains a review with matching local id', () async {
    final store = LocalReviewStore();
    await store.activateOwner('synthetic-owner-a');
    await Future.wait([
      store.enqueueFlag({'client_id': 'synthetic-1', 'reason': 'wrong'}),
      store.enqueueReview({'client_id': 'synthetic-1', 'card_id': 1001}),
    ]);
    expect(await store.removeFlagEntry('synthetic-1'), isTrue);
    expect(await store.flagOutbox(), isEmpty);
    expect((await store.outbox()).single['client_id'], 'synthetic-1');
  });

  test('calendar memo keeps month and year transitions distinct', () {
    final memo = LocalDayMemo();
    final previous = memo(DateTime(2026, 12, 31, 23, 59, 59, 999));
    final next = memo(DateTime(2027, 1, 1));
    expect(previous, DateTime(2026, 12, 31));
    expect(next, DateTime(2027, 1, 1));
    expect(memo(DateTime(2027, 1, 1, 23)), same(next));
  });

  test('UTC-3 midnight buckets actual local instants', () {
    final memo = LocalDayMemo();
    final before = DateTime.parse('2026-10-07T02:59:59.999Z').toLocal();
    final after = DateTime.parse('2026-10-07T03:00:00.000Z').toLocal();
    expect(before.timeZoneOffset, const Duration(hours: -3),
        reason: 'Run this coverage with TZ=America/Sao_Paulo');
    expect(memo(before), DateTime(2026, 10, 6));
    expect(memo(after), DateTime(2026, 10, 7));
    // Reuse the scheduler golden-vector leap-day input, without changing FSRS.
    final leap = DateTime.parse('2024-02-29T02:59:59.999Z').toLocal();
    expect(memo(leap), DateTime(2024, 2, 28));
  }, skip: !const bool.fromEnvironment('SYNC_LAB_UTC_MINUS_3'));

  testWidgets('offline transition cancels coalesced browser follow-up', (tester) async {
    final browser = _Browser();
    final held = Completer<void>();
    var writes = 0;
    var reads = 0;
    final coordinator = BrowserForegroundSyncCoordinator(
      platform: browser,
      hasSession: () => true,
      syncPending: () async {
        writes++;
        if (writes == 1) await held.future;
      },
      refreshIfIdle: () async { reads++; },
    )..start();
    try {
      final running = coordinator.sync();
      await tester.pump();
      browser.wake!();
      browser.online = false;
      held.complete();
      await tester.pump();
      await running;
      expect(writes, 1);
      expect(reads, 0);
      browser.online = true;
      await coordinator.sync();
      expect(writes, 2);
      expect(reads, 1);
    } finally {
      // Widget-test timer verification happens before addTearDown callbacks.
      // Dispose inside the test body so the periodic wake timer is cancelled.
      coordinator.dispose();
      if (!held.isCompleted) held.complete();
    }
  });
}
