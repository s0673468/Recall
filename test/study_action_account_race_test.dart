import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState, User;

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';

import 'support/recall_test_harness.dart';

final _now = DateTime.utc(2026, 10, 21, 12);

class _Gate {
  final entered = Completer<void>();
  final released = Completer<void>();
  Future<void> hold() async {
    entered.complete();
    await released.future;
  }

  void open() {
    if (!released.isCompleted) released.complete();
  }
}

class _Store extends LocalReviewStore {
  _Gate? mintGate;
  _Gate? committedGate;
  bool throwAfterCommit = false;
  final settledScopes = <String?>[];

  @override
  Future<String> newEventId() async {
    final gate = mintGate;
    mintGate = null;
    if (gate != null) await gate.hold();
    return super.newEventId();
  }

  @override
  Future<int> enqueueFlag(Map<String, dynamic> entry) async {
    final count = await super.enqueueFlag(entry);
    final gate = committedGate;
    committedGate = null;
    if (gate != null) await gate.hold();
    if (throwAfterCommit) throw StateError('Invented lost native reply');
    return count;
  }

  @override
  Future<int?> settleUnknownFlag(Object clientId, {String? ownerScope}) {
    settledScopes.add(ownerScope);
    return super.settleUnknownFlag(clientId, ownerScope: ownerScope);
  }
}

class _Api extends FakeRecallApi {
  final attempts = <String?>[];
  final _events = StreamController<AuthState>.broadcast();

  _Api()
    : super(
        [testCard(id: 101), testCard(id: 102)],
        decks: const [DeckRow(deckId: 1, name: 'Synthetic')],
      );

  @override
  Stream<AuthState> get onAuthStateChange => _events.stream;

  // Emit invented account transitions directly; no login or credentials.
  void activateAccount(String ownerId) {
    user = User(
      id: ownerId,
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      createdAt: _now.toIso8601String(),
    );
    _events.add(const AuthState(AuthChangeEvent.signedIn, null));
  }

  void disposeFixture() => unawaited(_events.close());

  @override
  Future<void> applyFlag(Map<String, dynamic> entry) async {
    attempts.add(currentUser?.id);
    throw StateError('Invented unavailable transport');
  }
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    if (ready()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Synthetic session did not settle');
}

Future<void> _activateAccount(
  ReviewController controller,
  _Api api,
  String ownerId,
) async {
  api.activateAccount(ownerId);
  await _until(
    () =>
        controller.store.isActiveOwner(api.currentUser!.id) &&
        !controller.state.loading &&
        controller.state.current != null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final hide in [false, true]) {
    for (final (afterCommit, unknownCommit) in [
      (false, false),
      (true, false),
      (true, true),
    ]) {
      test('${hide ? 'hide' : 'report'} account switch '
          '${unknownCommit
              ? 'after unknown commit'
              : afterCommit
              ? 'after commit'
              : 'during ID mint'} is isolated', () async {
        final api = _Api();
        final store = _Store();
        final controller = ReviewController(
          api: api,
          engine: FsrsEngine(),
          store: store,
          haptics: const ReviewHaptics(),
          clock: () => _now,
          beforeSessionLoad: () => store.activateOwner(api.currentUser!.id),
        );
        addTearDown(() {
          controller.dispose();
          api.disposeFixture();
        });
        await _activateAccount(controller, api, 'synthetic-account-a');
        final ownerA = store.activeOwnerScope!;
        final gate = _Gate();
        addTearDown(gate.open);
        if (afterCommit) {
          store.committedGate = gate;
          store.throwAfterCommit = unknownCommit;
        } else {
          store.mintGate = gate;
        }
        final action = hide
            ? controller.hideCurrent('dislike')
            : controller.flag('wrong');
        await gate.entered.future;
        await _activateAccount(controller, api, 'synthetic-account-b');
        final replacement = controller.state;
        final attempts = api.attempts.length;
        gate.open();
        await action;
        await store.flagOutbox();
        expect(await store.flagOutbox(), isEmpty);
        expect(controller.state, same(replacement));
        expect(controller.state.current?.id, 101);
        expect(controller.canUndo, isFalse);
        expect(controller.rateInFlight, isFalse);
        expect(controller.flagNotice, isNull);
        expect(await store.hiddenCardIds(), isEmpty);
        expect(api.attempts.length, attempts);
        expect(store.settledScopes, unknownCommit ? [ownerA] : isEmpty);
        expect(
          await store.flagOutbox(ownerScope: ownerA),
          afterCommit ? hasLength(1) : isEmpty,
        );
        await controller.refresh();
        expect(controller.state.queue.map((card) => card.id), [101, 102]);
      });
    }
  }
}
