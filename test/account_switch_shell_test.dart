import 'dart:async';

import 'package:flutter/material.dart';
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
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/stats_screen.dart';
import 'package:health_anki_flutter/features/settings/application/recall_prefs_controller.dart';
import 'package:health_anki_flutter/navigation/app_shell.dart';

import 'support/recall_test_harness.dart';

class _OwnerApi extends FakeRecallApi {
  final auth = StreamController<AuthState>.broadcast(sync: true);
  Completer<void>? ownerAGate;
  final pageOwners = <String>[];

  _OwnerApi() : super([]) {
    useOwner('A');
  }

  void useOwner(String owner) {
    user = User(
      id: owner,
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      createdAt: '2026-01-01T00:00:00Z',
    );
  }

  @override
  Stream<AuthState> get onAuthStateChange => auth.stream;

  @override
  Future<List<ConceptPage>> fetchConceptPages() async {
    final owner = user!.id;
    pageOwners.add(owner);
    if (owner == 'A') await ownerAGate?.future;
    return [
      ConceptPage(
        nodeId: 'owner-$owner',
        title: 'Account $owner primer',
        bodyHtml: 'Synthetic content for $owner',
        updatedAt: DateTime.utc(2026),
      ),
    ];
  }
}

class _NoBackground implements BackgroundSyncPlatform {
  @override
  Future<void> start(Future<String> Function() onSyncRequested) async {}
}

void main() {
  for (final delayedA in [false, true]) {
    testWidgets('account switch removes mounted aggregates immediately '
        '(previous response delayed: $delayedA)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      for (final name in [
        'com.llfbandit.app_links/messages',
        'com.llfbandit.app_links/events',
      ]) {
        final channel = MethodChannel(name);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
      }
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _OwnerApi();
      if (delayedA) api.ownerAGate = Completer<void>();
      addTearDown(api.auth.close);
      final prefs = RecallPrefsController(api: api);
      final controller = ReviewController(
        api: api,
        engine: FsrsEngine(),
        store: LocalReviewStore(),
        prefs: prefs,
      );
      await controller.load();
      final dependencies = RecallDependencies(
        api: api,
        reviewController: controller,
        recallPrefs: prefs,
        studyReminder: StudyReminderController(),
        backgroundSync: BackgroundSyncCoordinator(
          platform: _NoBackground(),
          sync: controller.syncPendingInBackground,
        ),
      );
      addTearDown(dependencies.dispose);
      await tester.pumpWidget(RecallApp(dependencies: dependencies));
      // A delayed primer request leaves a spinner, so do not settle it.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      Finder destination(String label) => find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      );
      await tester.tap(destination('Stats'));
      await tester.pump(const Duration(milliseconds: 250));
      final previousStats = tester.state<StatsScreenState>(
        find.byType(StatsScreen),
      );
      final previousRead = tester.state<ReadScreenState>(
        find.byType(ReadScreen),
      );

      if (!delayedA) {
        // Pushed account content is owned by the Navigator, outside AppShell.
        unawaited(
          Navigator.of(tester.element(find.byType(StatsScreen))).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  const Scaffold(body: Text('Account A open route')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Account A open route'), findsOneWidget);
      }

      api.useOwner('B');
      api.auth.add(const AuthState(AuthChangeEvent.userUpdated, null));
      await tester.pump();

      // The outgoing account must not remain mounted for a fade transition.
      expect(previousStats.mounted, isFalse);
      expect(previousRead.mounted, isFalse);
      expect(find.byType(AppShell), findsOneWidget);
      expect(find.text('Account A open route'), findsNothing);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(api.pageOwners, containsAll(['A', 'B']));
      api.ownerAGate?.complete();
      await tester.tap(destination('Read'));
      await tester.pumpAndSettle();
      expect(find.text('Account B primer'), findsWidgets);
      expect(find.text('Account A primer'), findsNothing);

      final currentRead = tester.state<ReadScreenState>(
        find.byType(ReadScreen),
      );
      // Same-account token refreshes retain tab state and cached reads.
      api.auth.add(const AuthState(AuthChangeEvent.tokenRefreshed, null));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ReadScreen)), same(currentRead));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
