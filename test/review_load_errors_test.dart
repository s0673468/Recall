// Account-setup retry and load-failure classification for ReviewController.
// Every user, card and server error here is invented.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show
        AuthApiException,
        AuthChangeEvent,
        AuthRetryableFetchException,
        AuthState,
        PostgrestException;

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_state.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/study_screen.dart';
import 'package:health_anki_flutter/features/settings/domain/recall_prefs.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

import 'support/recall_test_harness.dart';

final _now = DateTime.utc(2026, 10, 16, 12);

const _setupError = 'Recall could not prepare this account. Try again.';
const _offlineError =
    'Recall is offline and no saved study queue is available.';
const _serverError = "Recall's server returned an error. Try again later.";

ReviewCard _due(int id) => testCard(
  id: id,
  state: 2,
  reps: 3,
  due: _now.subtract(const Duration(hours: 1)),
  lastReview: _now.subtract(const Duration(days: 5)),
);

/// Emits auth events on demand and fails queue reads with [queueError].
class _Api extends FakeRecallApi {
  _Api() : super([_due(1), _due(2)]);

  final authStates = StreamController<AuthState>.broadcast();
  Object? queueError;

  @override
  Stream<AuthState> get onAuthStateChange => authStates.stream;

  @override
  Future<List<ReviewCard>> fetchQueue({
    int? deckId,
    Set<int>? includedDeckIds,
    int newLimit = 20,
    NewOrder order = NewOrder.oldestFirst,
    Set<int> excludeCardIds = const {},
  }) async {
    final error = queueError;
    if (error != null) throw error;
    return super.fetchQueue(
      deckId: deckId,
      includedDeckIds: includedDeckIds,
      newLimit: newLimit,
      order: order,
      excludeCardIds: excludeCardIds,
    );
  }
}

Future<void> _until(bool Function() ready, String what) async {
  for (var i = 0; i < 200; i++) {
    if (ready()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('$what did not happen');
}

/// An owner-aware store with no active account, as after a sign-out.
Future<LocalReviewStore> _releasedStore() async {
  final store = LocalReviewStore();
  await store.releaseOwner();
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('account setup retry', () {
    late _Api api;
    late LocalReviewStore store;
    late int setupCalls;
    late int setupFailures;

    ReviewController controller() {
      final c = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: store,
        clock: () => _now,
        beforeSessionLoad: () async {
          setupCalls++;
          if (setupFailures > 0) {
            setupFailures--;
            throw StateError('invented account setup failure');
          }
          await store.activateOwner(api.currentUser!.id);
        },
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() async {
      api = _Api()..user = testUser('invented-setup-owner');
      addTearDown(api.authStates.close);
      store = await _releasedStore();
      setupCalls = 0;
      setupFailures = 0;
    });

    Future<ReviewController> failedSignIn() async {
      final c = controller();
      api.authStates.add(const AuthState(AuthChangeEvent.signedIn, null));
      await _until(() => c.state.error == _setupError, 'setup error');
      expect(c.state.loading, isFalse);
      expect(setupCalls, 1);
      return c;
    }

    test('Retry re-runs a failed account setup and loads the queue', () async {
      setupFailures = 1;
      final c = await failedSignIn();

      await c.refresh();

      expect(setupCalls, 2);
      expect(store.isActiveOwner('invented-setup-owner'), isTrue);
      expect(c.state.loading, isFalse);
      expect(c.state.error, isNull);
      expect(c.state.queue.map((card) => card.id), [1, 2]);
    });

    test('a Retry whose setup fails again ends on the error, '
        'not a spinner', () async {
      setupFailures = 2;
      final c = await failedSignIn();

      await c.refresh();

      expect(setupCalls, 2);
      expect(c.state.loading, isFalse);
      expect(c.state.error, _setupError);
      expect(c.state.queue, isEmpty);

      // A third Retry, once setup works, recovers the session.
      await c.refresh();
      expect(setupCalls, 3);
      expect(c.state.loading, isFalse);
      expect(c.state.error, isNull);
      expect(c.state.queue.map((card) => card.id), [1, 2]);
    });

    test('Retry after a failed setup never loads into another account '
        'scope', () async {
      await store.activateOwner('invented-previous-owner');
      setupFailures = 1;
      final c = await failedSignIn();

      await c.refresh();

      expect(store.isActiveOwner('invented-setup-owner'), isTrue);
      expect(c.state.loading, isFalse);
      expect(c.state.queue.map((card) => card.id), [1, 2]);
    });

    test('load without an active account scope settles instead of '
        'spinning, and Retry prepares the account', () async {
      // No auth event yet: nothing has prepared this account's local scope.
      final c = controller();

      await c.load();

      expect(c.state.loading, isFalse);
      expect(c.state.error, _setupError);
      expect(setupCalls, 0);

      await c.refresh();

      expect(setupCalls, 1);
      expect(c.state.loading, isFalse);
      expect(c.state.error, isNull);
      expect(c.state.queue.map((card) => card.id), [1, 2]);
    });
  });

  group('load failure classification', () {
    ReviewController controller(_Api api) {
      final c = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        clock: () => _now,
      );
      addTearDown(c.dispose);
      return c;
    }

    final serverErrors = <String, Object>{
      'permission denied (RLS)': const PostgrestException(
        message: 'permission denied for table cards',
        code: '42501',
      ),
      'HTTP 500': const PostgrestException(
        message: 'invented internal error',
        code: '500',
      ),
      'missing RPC': const PostgrestException(
        message: 'Could not find the function public.invented_rpc',
        code: 'PGRST202',
      ),
      'rejected session': const AuthApiException(
        'invented: refresh token revoked',
        statusCode: '400',
      ),
    };
    serverErrors.forEach((label, error) {
      test('a server error is not reported as offline ($label)', () async {
        final api = _Api()..queueError = error;
        addTearDown(api.authStates.close);
        final c = controller(api);

        await c.load();

        expect(c.state.loading, isFalse);
        expect(c.state.error, _serverError);
        expect(c.state.offline, isFalse);
        expect(c.state.serverError, isTrue);
      });
    });

    final connectivityErrors = <String, Object>{
      'socket': const SocketException('invented: network is unreachable'),
      'DNS/XHR client failure': http.ClientException(
        'invented: Failed host lookup',
      ),
      'timeout': TimeoutException('invented: request timed out'),
      'auth refresh without a connection': AuthRetryableFetchException(
        message: 'invented: Failed to fetch',
      ),
      'unclassified': StateError('invented transport failure'),
    };
    connectivityErrors.forEach((label, error) {
      test('a connection failure is still reported as offline '
          '($label)', () async {
        final api = _Api()..queueError = error;
        addTearDown(api.authStates.close);
        final c = controller(api);

        await c.load();

        expect(c.state.loading, isFalse);
        expect(c.state.error, _offlineError);
        expect(c.state.serverError, isFalse);
      });
    });

    test('a server error with a saved snapshot keeps studying it but is '
        'labelled as a server error', () async {
      final api = _Api();
      addTearDown(api.authStates.close);
      await controller(api).load();
      // Let the off-critical-path snapshot save land.
      await pumpEventQueue();

      api.queueError = const PostgrestException(
        message: 'invented service unavailable',
        code: '503',
      );
      final cold = controller(api);
      await cold.load();

      expect(cold.state.loading, isFalse);
      expect(cold.state.error, isNull);
      expect(cold.state.queue.map((card) => card.id), [1, 2]);
      // Same saved-queue behaviour as offline, honest label.
      expect(cold.state.offline, isTrue);
      expect(cold.state.serverError, isTrue);

      // A later successful load clears the label.
      api.queueError = null;
      await cold.load();
      expect(cold.state.offline, isFalse);
      expect(cold.state.serverError, isFalse);
    });

    test('a connection failure with a saved snapshot is unchanged', () async {
      final api = _Api();
      addTearDown(api.authStates.close);
      await controller(api).load();
      await pumpEventQueue();

      api.queueError = http.ClientException('invented: connection refused');
      final cold = controller(api);
      await cold.load();

      expect(cold.state.loading, isFalse);
      expect(cold.state.error, isNull);
      expect(cold.state.queue.map((card) => card.id), [1, 2]);
      expect(cold.state.offline, isTrue);
      expect(cold.state.serverError, isFalse);
    });
  });

  group('study status line', () {
    Future<void> pump(WidgetTester tester, ReviewState state) async {
      final c = _StateController(state);
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(411, 914);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildRecallTheme(),
          home: Scaffold(body: StudyScreen(controller: c, nativeIos: false)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('names a server error instead of claiming offline', (
      tester,
    ) async {
      await pump(
        tester,
        ReviewState(
          loading: false,
          queue: [_due(1)],
          offline: true,
          serverError: true,
          pendingSync: 2,
        ),
      );

      expect(find.text('Server error · 2 waiting to sync'), findsOneWidget);
      expect(find.textContaining('Offline'), findsNothing);
    });

    testWidgets('still says offline for a connection failure', (tester) async {
      await pump(
        tester,
        ReviewState(loading: false, queue: [_due(1)], offline: true),
      );

      expect(find.text('Offline'), findsOneWidget);
    });
  });
}

/// Renders StudyScreen for a fixed state without the real controller.
class _StateController extends ChangeNotifier implements ReviewController {
  _StateController(this.state);

  @override
  final ReviewState state;

  @override
  String? get flagNotice => null;

  @override
  bool get rateInFlight => false;

  @override
  bool get canUndo => false;

  @override
  bool get undoInFlight => false;

  @override
  int get remediationRevision => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
