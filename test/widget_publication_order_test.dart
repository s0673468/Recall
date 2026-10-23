import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/core/widgets/recall_widget_bridge.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';

class _DelayedWidgetStore implements RecallWidgetStore {
  final counts = <int>[];
  final gates = <int, Completer<void>>{};
  final started = <int, Completer<void>>{};
  int? visibleCount;

  @override
  Future<void> update(RecallWidgetSnapshot snapshot) async {
    final call = counts.length;
    counts.add(snapshot.dueCount);
    started[call]?.complete();
    await gates[call]?.future;
    visibleCount = snapshot.dueCount;
  }

  @override
  Future<void> clear() async => visibleCount = null;
}

void main() {
  final at = DateTime.utc(2026, 10, 23, 12);
  ReviewState state(int count) => ReviewState(
    loading: false,
    globalDueCount: count,
    globalDueUpdatedAt: at,
  );

  test(
    'returning to the published count queues after a pending different count',
    () async {
      final store = _DelayedWidgetStore();
      final publisher = RecallWidgetPublisher(store: store);
      Future<void> publish(int count) => publisher.publish(
        signedIn: true,
        ownerId: 'synthetic-owner',
        state: state(count),
      );
      await publish(5);
      final gate = store.gates[1] = Completer<void>();
      final started = store.started[1] = Completer<void>();
      final older = publish(4);
      await started.future;
      final latest = publish(5);
      gate.complete();
      await Future.wait([older, latest]);

      expect(store.counts, [5, 4, 5]);
      expect(store.visibleCount, 5);
      await publish(5);
      expect(store.counts, [5, 4, 5]);
    },
  );

  test(
    'an older equal snapshot cannot clear the latest queued update',
    () async {
      final store = _DelayedWidgetStore();
      final publisher = RecallWidgetPublisher(store: store);
      Future<void> publish(int count) => publisher.publish(
        signedIn: true,
        ownerId: 'synthetic-owner',
        state: state(count),
      );
      final firstGate = store.gates[0] = Completer<void>();
      final firstStarted = store.started[0] = Completer<void>();
      final lastGate = store.gates[2] = Completer<void>();
      final lastStarted = store.started[2] = Completer<void>();
      final first = publish(5);
      await firstStarted.future;
      final middle = publish(4);
      final last = publish(5);
      firstGate.complete();
      await lastStarted.future;
      final repeated = publish(5);
      lastGate.complete();
      await Future.wait([first, middle, last, repeated]);

      expect(store.counts, [5, 4, 5]);
      expect(store.visibleCount, 5);
    },
  );
}
