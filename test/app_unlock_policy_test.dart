import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/app/recall_app.dart';
import 'package:health_anki_flutter/app/recall_dependencies.dart';
import 'package:health_anki_flutter/core/background/background_sync_coordinator.dart';
import 'package:health_anki_flutter/features/reminders/application/study_reminder_controller.dart';
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/navigation/app_shell.dart';

class _SignedInRecallApi implements RecallApi {
  final User user = User(
    id: 'user-1',
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: DateTime.utc(2026).toIso8601String(),
  );

  @override
  User? get currentUser => user;

  @override
  Stream<AuthState> get onAuthStateChange => const Stream.empty();

  @override
  Future<Map<int, ({int due, int neu})>> fetchDeckCounts() async => const {};

  @override
  Future<List<ReviewLogEntry>> fetchReviewLog({int days = 190}) async =>
      const [];

  @override
  Future<Map<String, String>> fetchNoteTags() async => const {};

  @override
  Future<List<ConceptNodeInfo>> fetchConceptNodes() async => const [];

  @override
  Future<List<ConceptPage>> fetchConceptPages() async => const [];

  @override
  Future<List<DateTime>> fetchDueDates({Set<int>? includedDeckIds}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopBackgroundSyncPlatform implements BackgroundSyncPlatform {
  @override
  Future<void> start(Future<String> Function() onSyncRequested) async {}
}

void main() {
  test('a restored Recall session opens without a second device lock', () {
    final app = File('lib/app/recall_app.dart').readAsStringSync();
    final dependencies = File('pubspec.yaml').readAsStringSync();
    final resolvedDependencies = File('pubspec.lock').readAsStringSync();
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final androidHost = File(
      'android/app/src/main/kotlin/com/german/health_anki_flutter/'
      'MainActivity.kt',
    ).readAsStringSync();

    expect(app, isNot(contains('BiometricUnlockGate')));
    expect(app, isNot(contains('supportsRecallBiometricUnlock')));
    expect(dependencies, isNot(contains('local_auth:')));
    expect(resolvedDependencies, isNot(contains('local_auth')));
    expect(androidHost, contains('SharedPreferencesPlugin'));
    expect(androidHost, isNot(contains('LocalAuthPlugin')));
    expect(androidHost, isNot(contains('FlutterPasskeysPlugin')));
    expect(plist, isNot(contains('NSFaceIDUsageDescription')));
    expect(
      File(
        'lib/features/auth/presentation/widgets/biometric_unlock_gate.dart',
      ).existsSync(),
      isFalse,
    );
  });

  testWidgets('a signed-in native session paints the study shell directly', (
    tester,
  ) async {
    const appLinksMessages = MethodChannel('com.llfbandit.app_links/messages');
    const appLinksEvents = MethodChannel('com.llfbandit.app_links/events');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      appLinksMessages,
      (_) async => null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      appLinksEvents,
      (_) async => null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        appLinksMessages,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        appLinksEvents,
        null,
      );
    });
    SharedPreferences.setMockInitialValues({});
    final api = _SignedInRecallApi();
    final prefs = RecallPrefsController(api: api);
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: LocalReviewStore(),
      prefs: prefs,
    );
    final reminder = StudyReminderController();
    final dependencies = RecallDependencies(
      reviewController: controller,
      api: api,
      recallPrefs: prefs,
      backgroundSync: BackgroundSyncCoordinator(
        platform: _NoopBackgroundSyncPlatform(),
        sync: () async =>
            const BackgroundSyncReport(attempted: 0, delivered: 0, pending: 0),
      ),
      studyReminder: reminder,
    );
    addTearDown(dependencies.dispose);

    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(RecallApp(dependencies: dependencies));
    await tester.pumpAndSettle();

    expect(find.byType(AppShell), findsOneWidget);
    expect(find.text('All caught up'), findsOneWidget);
    expect(find.text('Recall is locked'), findsNothing);
    expect(find.text('Unlock Recall'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
