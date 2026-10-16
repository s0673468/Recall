import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../tool/fixtures/synthetic_native_outbox_cost_main.dart';

class _ControlledDelegate extends InMemorySharedPreferencesStore {
  _ControlledDelegate() : super.empty();

  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool hold = false;
  bool refuse = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (hold) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    if (refuse) return false;
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'probe only counts owner outbox writes after the delegate ACK',
    () async {
      final delegate = _ControlledDelegate()..hold = true;
      final probe = NativeOutboxWriteProbe(delegate)
        ..resetFor('flutter.recall_outbox_v1:owner:synthetic');
      final pending = probe.setValue(
        'String',
        'flutter.recall_outbox_v1:owner:synthetic',
        'é😀',
      );
      await delegate.entered.future;
      expect(probe.acknowledgedWrites, 0);
      delegate.release.complete();
      expect(await pending, isTrue);
      expect(probe.acknowledgedWrites, 1);
      expect(probe.acknowledgedChars, 3);
      expect(probe.acknowledgedUtf8Bytes, 6);
      expect(probe.ackTotalUs, greaterThanOrEqualTo(0));
      expect(
        await probe.setValue('String', 'flutter.unrelated', 'other'),
        isTrue,
      );
      expect(probe.acknowledgedWrites, 1);
    },
  );

  test(
    'refused native writes are forwarded and never reported as ACKs',
    () async {
      final delegate = _ControlledDelegate()..refuse = true;
      final probe = NativeOutboxWriteProbe(delegate)
        ..resetFor('flutter.recall_outbox_v1:owner:synthetic');
      expect(
        await probe.setValue(
          'String',
          'flutter.recall_outbox_v1:owner:synthetic',
          '[]',
        ),
        isFalse,
      );
      expect(probe.acknowledgedWrites, 0);
      expect(probe.acknowledgedChars, 0);
    },
  );

  test(
    'real controller, Store and API drain generated events in order',
    () async {
      final previous = SharedPreferencesStorePlatform.instance;
      final delegate = InMemorySharedPreferencesStore.empty();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = delegate;
      try {
        final sample = await measureSyntheticOutboxCost(
          pendingCount: 3,
          delegate: delegate,
        );
        final metrics = sample.metrics();
        final counts = metrics['counts'] as Map<String, dynamic>;
        expect(sample.pendingSeeded, 3);
        expect(sample.store.markedBeforeTransport.length, 3);
        // The first send is marked alone; the other two in one batch write.
        expect(counts['mark_calls'], 1);
        expect(sample.store.batchMarkCalls, 1);
        expect(counts['remove_calls'], 1);
        expect(counts['native_ack_writes'], 3);
        expect(counts['apply_review_requests'], 3);
        expect(counts['accepted_unique'], 3);
        expect(counts['pending_after'], 0);
      } finally {
        SharedPreferencesStorePlatform.instance = previous;
        SharedPreferences.resetStatic();
      }
    },
  );

  test('only two fixed runtime routes select a workload', () {
    expect(syntheticOutboxCountFromRoute('/recall-outbox-cost/128'), 128);
    expect(syntheticOutboxCountFromRoute('/recall-outbox-cost/512'), 512);
    expect(
      () => syntheticOutboxCountFromRoute('/recall-outbox-cost/513'),
      throwsStateError,
    );
  });
}
