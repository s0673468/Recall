// Baseline-compatible regression: only existing Controller/Store APIs are used.
// Invented records and one in-memory native backend; no external service calls.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_acceptance_fixture.dart';

enum _Kind { review, flag, dismiss }

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> hold() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

Map<String, dynamic> _entry(String id, _Kind kind) => {
  'client_id': id,
  'card_id': id == 'invented-a'
      ? 101
      : id == 'invented-b'
      ? 102
      : 103,
  if (kind == _Kind.review) 'rating': 3,
  if (kind == _Kind.review) 'delivery_attempted': false,
  if (kind != _Kind.review) 'reason': 'wrong',
  if (kind == _Kind.dismiss) 'op': ReviewController.dismissOp,
};

String _base(_Kind kind) =>
    kind == _Kind.review ? 'recall_outbox_v1' : 'flag_outbox_v1';

class _Api extends SanitizedRecallApi {
  _Api(this.kind, this.accepted)
    : super(
        dataset: SanitizedRecallDataset(
          now: DateTime.utc(2026, 10, 15),
          decks: const [],
          cards: const [],
          reviews: const [],
          noteTags: const {},
          conceptNodes: const [],
          conceptPages: const [],
        ),
        scenario: AcceptanceScenario.empty,
      );

  final _Kind kind;
  final Set<String> accepted;
  final first = _Gate();
  final second = _Gate();
  final attempts = <String>[];

  Future<void> _send(String id) async {
    attempts.add(id);
    if (id == 'invented-a') {
      await first.hold();
      accepted.add(id); // Models the server's idempotent accepted event id.
      return;
    }
    if (id == 'invented-b') await second.hold();
    throw StateError('Invented unacknowledged transport refusal');
  }

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    expect(kind, _Kind.review);
    await _send(entry['client_id'] as String);
    return 10101;
  }

  @override
  Future<void> applyFlag(Map<String, dynamic> entry) async {
    expect(kind, _Kind.flag);
    await _send(entry['client_id'] as String);
  }

  @override
  Future<void> dismissFlag({
    required int cardId,
    required String clientEventId,
  }) async {
    expect(kind, _Kind.dismiss);
    await _send(clientEventId);
  }
}

Future<({LocalReviewStore store, ReviewController controller, _Api api})> _tab(
  _Kind kind,
  Set<String> accepted,
) async {
  final api = _Api(kind, accepted);
  final store = LocalReviewStore();
  await store.activateOwner(api.currentUser!.id);
  final controller = ReviewController(
    api: api,
    engine: FsrsEngine(),
    store: store,
    haptics: const ReviewHaptics(),
  );
  addTearDown(() {
    api.first.open();
    api.second.open();
    controller.dispose();
    api.disposeFixture();
  });
  return (store: store, controller: controller, api: api);
}

Future<List<String>> _durableIds(
  SharedPreferencesStorePlatform native,
  _Kind kind,
  String owner,
) async {
  final values = await native.getAll();
  final raw = values['flutter.${_base(kind)}:owner:$owner'] as String?;
  return [
    for (final entry in jsonDecode(raw ?? '[]') as List)
      (entry as Map)['client_id'] as String,
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final kind in _Kind.values) {
    for (final concurrentAppend in [false, true]) {
      test(
        'late duplicate $kind server ACK preserves unacknowledged B: append=$concurrentAppend',
        () async {
          final previous = SharedPreferencesStorePlatform.instance;
          SharedPreferences.resetStatic();
          final native = InMemorySharedPreferencesStore.withData({
            'flutter.${_base(kind)}': jsonEncode([
              _entry('invented-a', kind),
              _entry('invented-b', kind),
            ]),
          });
          SharedPreferencesStorePlatform.instance = native;
          addTearDown(() {
            SharedPreferencesStorePlatform.instance = previous;
            SharedPreferences.resetStatic();
          });
          final accepted = <String>{};
          final first = await _tab(kind, accepted);
          final second = await _tab(kind, accepted);
          final owner = first.store.activeOwnerScope!;
          expect(second.store.activeOwnerScope, owner);

          final firstSync = first.controller.syncPending();
          await first.api.first.entered.future.timeout(
            const Duration(seconds: 5),
          );
          final secondSync = second.controller.syncPending();
          await second.api.first.entered.future.timeout(
            const Duration(seconds: 5),
          );
          // Both controllers captured [A, B] and are waiting for their A reply.
          first.api.first.open();
          await first.api.second.entered.future.timeout(
            const Duration(seconds: 5),
          );
          first.api.second.open(); // B fails; only A was acknowledged.
          await firstSync;
          expect(await _durableIds(native, kind, owner), ['invented-b']);

          second.api.first.open(); // A was already removed by the other tab.
          await second.api.second.entered.future.timeout(
            const Duration(seconds: 5),
          );
          if (concurrentAppend) {
            if (kind == _Kind.review) {
              await first.store.enqueueReview(_entry('invented-c', kind));
            } else {
              await first.store.enqueueFlag(_entry('invented-c', kind));
            }
          }
          second.api.second.open(); // No B acknowledgement in this tab either.
          await secondSync;
          expect(
            await _durableIds(native, kind, owner),
            ['invented-b', if (concurrentAppend) 'invented-c'],
            reason: 'ACK_DRAIN_PRESERVE_UNACKNOWLEDGED_B',
          );
          expect(first.api.attempts, ['invented-a', 'invented-b']);
          expect(second.api.attempts, ['invented-a', 'invented-b']);
          expect(accepted, {'invented-a'});
          if (kind == _Kind.review) {
            expect(
              second.controller.state.pendingSync,
              concurrentAppend ? 2 : 1,
            );
          }
        },
      );
    }
  }
}
