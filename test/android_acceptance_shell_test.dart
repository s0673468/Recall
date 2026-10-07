import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import '../tool/android_acceptance.dart';
import 'support/android_acceptance_fixture.dart';

void main() {
  testWidgets(
    'fixture UI preserves offline outbox and attempted Undo safeguard',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      for (final channel in ['studyReminder', 'backgroundSync', 'widget']) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel('com.german.ankiReview/$channel'),
          (_) async => true,
        );
      }
      await tester.pumpWidget(const AndroidAcceptanceApp());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('TEST DATA · invented backend'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Go offline'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).at(0),
        AndroidAcceptanceApi.email,
      );
      await tester.enterText(find.byType(TextField).at(1), 'invented-only');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Show answer'), findsOneWidget);
      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();
      final preferences = await SharedPreferences.getInstance();
      final ledger =
          jsonDecode(preferences.getString(AndroidAcceptanceApi.journalKey)!)
              as List;
      expect(ledger, hasLength(1));
      expect(find.text('Synced reviews cannot be undone'), findsOneWidget);
      final store = LocalReviewStore();
      await store.activateOwner((ledger.single as Map)['owner'] as String);
      await tester.tap(find.text('Go offline'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show answer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();
      expect(await store.outbox(), hasLength(1));
      expect(
        jsonDecode(preferences.getString(AndroidAcceptanceApi.journalKey)!)
            as List,
        hasLength(1),
      );
      expect(find.byTooltip('Undo').hitTestable(), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(const AndroidAcceptanceApp());
      await tester.pumpAndSettle();
      expect(find.text('Reconnect'), findsOneWidget);
      expect(await store.outbox(), hasLength(1));
      await tester.tap(find.text('Reconnect'));
      await tester.pumpAndSettle();
      expect(await store.outbox(), isEmpty);
      expect(
        jsonDecode(preferences.getString(AndroidAcceptanceApi.journalKey)!)
            as List,
        hasLength(2),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
