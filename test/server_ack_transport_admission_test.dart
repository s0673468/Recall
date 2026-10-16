// Controller-only transport admission; all values are invented local fixtures.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import 'support/recall_acceptance_fixture.dart';

String _base(bool flag) => flag ? 'flag_outbox_v1' : 'recall_outbox_v1';

Map<String, dynamic> _entry(String id, bool flag) => {
  'client_id': id,
  'card_id': id == 'invented-a' ? 101 : 102,
  if (flag) 'reason': 'wrong',
  if (!flag) 'rating': 3,
  if (!flag) 'delivery_attempted': false,
};

InMemorySharedPreferencesStore _install(
  bool flag,
  List<Map<String, dynamic>> rows,
) {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = InMemorySharedPreferencesStore.withData({
    'flutter.${_base(flag)}': jsonEncode(rows),
  });
  SharedPreferencesStorePlatform.instance = native;
  addTearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  return native;
}

Future<List<Map<String, dynamic>>> _persisted(
  SharedPreferencesStorePlatform native,
  bool flag, {
  String? owner,
}) async {
  final values = await native.getAll();
  final key = 'flutter.${_base(flag)}${owner == null ? '' : ':owner:$owner'}';
  return [
    for (final row in jsonDecode(values[key] as String? ?? '[]') as List)
      Map<String, dynamic>.from(row as Map),
  ];
}

enum _TransportKind { review, flag, dismiss }

class _AdmissionApi extends SanitizedRecallApi {
  _AdmissionApi()
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

  int sent = 0;

  @override
  Future<int?> applyReview(Map<String, dynamic> entry) async {
    sent++;
    return 10101;
  }

  @override
  Future<void> applyFlag(Map<String, dynamic> entry) async {
    sent++;
  }

  @override
  Future<void> dismissFlag({
    required int cardId,
    required String clientEventId,
  }) async {
    sent++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final kind in _TransportKind.values) {
    test(
      'unidentified or duplicate $kind events never reach transport or disappear',
      () async {
        for (final invalid in [
          'missing',
          'empty',
          'non-scalar',
          'duplicate',
          'wire-collision',
        ]) {
          final flag = kind != _TransportKind.review;
          final a = {
            ..._entry('invented-a', flag),
            if (kind == _TransportKind.dismiss)
              'op': ReviewController.dismissOp,
          };
          if (invalid == 'missing') a.remove('client_id');
          if (invalid == 'empty') a['client_id'] = '';
          if (invalid == 'non-scalar') a['client_id'] = true;
          if (invalid == 'wire-collision') a['client_id'] = 11;
          final rows = [
            a,
            if (invalid == 'duplicate') {...a, 'card_id': 999},
            if (invalid == 'wire-collision') {...a, 'client_id': '11'},
            _entry('invented-b', flag),
          ];
          final native = _install(flag, rows);
          final api = _AdmissionApi();
          final store = LocalReviewStore();
          final controller = ReviewController(
            api: api,
            engine: FsrsEngine(),
            store: store,
            haptics: const ReviewHaptics(),
          );
          try {
            await controller.syncPending();
            await controller.syncPending();
            expect(
              api.sent,
              0,
              reason: 'ACK_DRAIN_UNIDENTIFIED_EVENT_MUST_NOT_TRANSPORT',
            );
            expect(await _persisted(native, flag), rows);
            await expectLater(
              store.clear(requireEmptyOutboxes: true),
              throwsA(isA<LocalOutboxNotEmptyException>()),
            );
            if (!flag) expect(controller.state.pendingSync, rows.length);
          } finally {
            controller.dispose();
            api.disposeFixture();
          }
        }
      },
    );
  }
}
