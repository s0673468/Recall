import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;

import 'package:health_anki_flutter/app/recall_app.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/decks_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/read_screen.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/stats_screen.dart';
import 'package:health_anki_flutter/features/settings/presentation/screens/settings_screen.dart';

import '../tool/acceptance/recall_acceptance_fixture.dart';

void main() {
  const phoneSize = Size(411, 914);
  final fixedNow = DateTime.utc(2026, 8, 23, 12);

  Finder navigationLabel(String label) => find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  );

  test('sanitized corpus has production-scale, non-sensitive coverage', () {
    final data = SanitizedRecallDataset.productionScale(now: fixedNow);

    expect(data.cards, hasLength(1600));
    expect(data.decks, hasLength(32));
    expect(data.reviews, hasLength(12000));
    expect(data.conceptNodes, hasLength(72));
    expect(data.conceptPages, hasLength(72));
    expect(data.conceptPages.last.nodeId, 'concept-72');
    expect(data.conceptPages.last.title.toLowerCase(), contains('concept 72'));
    expect(data.conceptPages.last.title.length, greaterThan(70));
    expect(data.noteTags, hasLength(1600));
    expect(data.cards.map((card) => card.id).toSet(), hasLength(1600));
    expect(data.cards.map((card) => card.guid).toSet(), hasLength(1600));
    expect(
      data.decks.every(
        (deck) =>
            data.cards.where((card) => card.deckId == deck.deckId).length == 50,
      ),
      isTrue,
    );
    expect(data.reviews.first.at.isBefore(data.reviews.last.at), isTrue);
    expect(
      data.reviews.last.at.difference(data.reviews.first.at).inDays,
      greaterThanOrEqualTo(189),
    );
    expect(
      List.generate(
        data.reviews.length - 1,
        (i) => !data.reviews[i].at.isAfter(data.reviews[i + 1].at),
      ).every((ordered) => ordered),
      isTrue,
    );
    expect(data.cards.any((card) => card.isNew), isTrue);
    expect(data.cards.any((card) => card.state == 3), isTrue);
    expect(
      data.cards.any(
        (card) => card.due != null && !card.due!.isAfter(data.now),
      ),
      isTrue,
    );
    expect(
      data.cards.any((card) => card.due != null && card.due!.isAfter(data.now)),
      isTrue,
    );
    expect(
      List.generate(
        SanitizedRecallDataset.conceptCount,
        (i) => 'concept-${i + 1}',
      ).every(
        (nodeId) => data.noteTags.values.any((tags) => tags.contains(nodeId)),
      ),
      isTrue,
    );
    expect(automaticReviewDeckIds(data.decks), hasLength(28));
    expect(
      data.decks.where((deck) => deck.name.startsWith('Opt-in::')),
      hasLength(2),
    );
    expect(data.cards.any((card) => card.hasLatex), isTrue);
    expect(data.cards.any((card) => card.front.contains('<code>')), isTrue);
    expect(data.cards.any((card) => card.front.length > 300), isTrue);
    expect(data.cards.any((card) => card.back.contains('<img')), isTrue);
    expect(data.cards.any((card) => card.latexSvg != null), isTrue);
    expect(data.cards.any((card) => card.contentRevalidationPending), isTrue);
    expect(
      data.cards.every((card) => card.guid.startsWith('sanitized-guid-')),
      isTrue,
    );
  });

  test('acceptance scenarios reject misspelled state names', () {
    expect(AcceptanceScenario.parse('rich'), AcceptanceScenario.rich);
    expect(
      () => AcceptanceScenario.parse('parital_stats_failure'),
      throwsArgumentError,
    );
  });

  test('sanitized cloud state is isolated between learner accounts', () async {
    final data = SanitizedRecallDataset.productionScale(now: fixedNow);
    final api = SanitizedRecallApi(
      dataset: data,
      scenario: AcceptanceScenario.signedOut,
    );
    addTearDown(api.disposeFixture);

    await api.signIn(email: 'account-a@example.invalid', password: 'local');
    final accountA = api.currentUser!.id;
    final card = (await api.fetchQueue()).first;
    await api.saveRecallPrefs({'new_limit': 37});
    await api.applyReview({
      'card_id': card.id,
      'guid': card.guid,
      'last_review': fixedNow.toIso8601String(),
      'rating': 3,
      'state': 2,
      'due': fixedNow.add(const Duration(days: 3)).toIso8601String(),
    });
    await api.applyFlag({'card_id': card.id, 'reason': 'confusing'});

    await api.signIn(email: 'account-b@example.invalid', password: 'local');
    expect(api.currentUser!.id, isNot(accountA));
    expect(await api.fetchRecallPrefs(), isNull);
    expect(api.appliedReviewCardIds, isEmpty);
    expect(api.appliedFlags, isEmpty);
    expect((await api.fetchQueue()).map((item) => item.id), contains(card.id));

    await api.signIn(email: 'account-a@example.invalid', password: 'local');
    expect(await api.fetchRecallPrefs(), containsPair('new_limit', 37));
    expect(api.appliedReviewCardIds, [card.id]);
    expect(api.appliedFlags.single['reason'], 'confusing');
  });

  test('offline rating survives reconstruction and replays once', () async {
    final offline = await createSanitizedAcceptanceDependencies(
      scenario: AcceptanceScenario.offline,
      now: fixedNow,
    );
    final ratedCardId = offline.reviewController.state.current!.id;
    offline.reviewController.flip();
    await offline.reviewController.rate(Rating.good);
    expect(offline.reviewController.state.pendingSync, 1);
    offline.dispose();
    (offline.api as SanitizedRecallApi).disposeFixture();

    final restarted = await createSanitizedAcceptanceDependencies(
      scenario: AcceptanceScenario.rich,
      now: fixedNow,
      resetPreferences: false,
    );
    addTearDown(() {
      restarted.dispose();
      (restarted.api as SanitizedRecallApi).disposeFixture();
    });
    final restartedApi = restarted.api as SanitizedRecallApi;
    await restarted.reviewController.syncPending();
    expect(restartedApi.appliedReviewCardIds, [ratedCardId]);
    expect(restarted.reviewController.state.pendingSync, 0);

    await restarted.reviewController.syncPending();
    expect(restartedApi.appliedReviewCardIds, [ratedCardId]);
  });

  testWidgets('a learner can traverse and use the production-scale app', (
    tester,
  ) async {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dependencies = await createSanitizedAcceptanceDependencies(
      scenario: AcceptanceScenario.rich,
      now: fixedNow,
    );
    final api = dependencies.api as SanitizedRecallApi;

    await tester.pumpWidget(RecallApp(dependencies: dependencies));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('recall_shell')), findsOneWidget);
    expect(find.byKey(const Key('recall_study_card')), findsOneWidget);
    expect(find.byKey(const ValueKey('study_catch_up_offer')), findsOneWidget);

    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show answer'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('study_rating_bar')), findsOneWidget);

    await tester.tap(find.byTooltip('Flag card'));
    await tester.pumpAndSettle();
    expect(find.text('Flag this card'), findsOneWidget);
    await tester.tap(find.text('Confusing'));
    await tester.pumpAndSettle();
    expect(find.text('Card flagged'), findsOneWidget);
    expect(api.appliedFlags.single['reason'], 'confusing');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Good'));
    await tester.pumpAndSettle();
    expect(dependencies.reviewController.state.reviewedThisSession, 1);
    expect(find.byTooltip('Undo last rating'), findsOneWidget);
    await tester.tap(find.byTooltip('Undo last rating'));
    await tester.pumpAndSettle();
    expect(dependencies.reviewController.state.reviewedThisSession, 0);

    await tester.tap(navigationLabel('Decks'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recall_deck_hero')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('recall_deck_row_Portuguese')),
      500,
      scrollable: find
          .descendant(
            of: find.byType(DecksScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      find.byKey(const ValueKey('recall_deck_row_Portuguese')),
      findsOneWidget,
    );

    await tester.tap(navigationLabel('Stats'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recall_retention_hero')), findsOneWidget);
    expect(find.byKey(const Key('recall_stats_history_strip')), findsOneWidget);
    final statsScroll = find
        .descendant(
          of: find.byType(StatsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('stats_section_content_forecast')),
      500,
      scrollable: statsScroll,
    );
    expect(
      find.byKey(const ValueKey('stats_section_content_forecast')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('recall_concepts_panel')),
      500,
      scrollable: statsScroll,
    );
    expect(find.byKey(const Key('recall_concepts_panel')), findsOneWidget);

    await tester.tap(navigationLabel('Read'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('read_content')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('recall_primer_search')),
      400,
      scrollable: find
          .descendant(
            of: find.byType(ReadScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.byKey(const Key('recall_primer_search')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('recall_primer_search')),
      'concept 72',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('recall_primer_row_concept-72')),
      findsOneWidget,
    );

    await tester.tap(navigationLabel('Study'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Scheduling'), findsOneWidget);
    expect(find.text('Daily reminder'), findsOneWidget);
    expect(find.byTooltip('Decrease New cards / day'), findsOneWidget);
    expect(find.byTooltip('Increase New cards / day'), findsOneWidget);
    final settingsScroll = find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Per-deck new-card limits'),
      500,
      scrollable: settingsScroll,
    );
    expect(find.text('Per-deck new-card limits'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Account'),
      500,
      scrollable: settingsScroll,
    );
    expect(find.text('Account'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    dependencies.dispose();
    await tester.pump();
  });

  testWidgets(
    'signed-out, empty, offline, and partial-failure states stay usable',
    (tester) async {
      tester.view.physicalSize = phoneSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final signedOut = await createSanitizedAcceptanceDependencies(
        scenario: AcceptanceScenario.signedOut,
        now: fixedNow,
      );
      await tester.pumpWidget(RecallApp(dependencies: signedOut));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recall_auth')), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Email'),
        'learner@example.invalid',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'local-only-password',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recall_shell')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      signedOut.dispose();
      final empty = await createSanitizedAcceptanceDependencies(
        scenario: AcceptanceScenario.empty,
        now: fixedNow,
      );
      await tester.pumpWidget(RecallApp(dependencies: empty));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('study_done')), findsOneWidget);
      expect(find.text('All caught up'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      empty.dispose();
      final offline = await createSanitizedAcceptanceDependencies(
        scenario: AcceptanceScenario.offline,
        now: fixedNow,
      );
      await tester.pumpWidget(RecallApp(dependencies: offline));
      await tester.pumpAndSettle();
      expect(find.text('Offline'), findsOneWidget);
      expect(find.byKey(const Key('recall_study_card')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      offline.dispose();
      final partial = await createSanitizedAcceptanceDependencies(
        scenario: AcceptanceScenario.partialStatsFailure,
        now: fixedNow,
      );
      await tester.pumpWidget(RecallApp(dependencies: partial));
      await tester.pumpAndSettle();
      await tester.tap(navigationLabel('Stats'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recall_retention_hero')), findsOneWidget);
      final partialStatsScroll = find
          .descendant(
            of: find.byType(StatsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('stats_section_error_forecast')),
        500,
        scrollable: partialStatsScroll,
      );
      expect(
        find.byKey(const ValueKey('stats_section_error_forecast')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('recall_concepts_panel')),
        500,
        scrollable: partialStatsScroll,
      );
      expect(find.byKey(const Key('recall_concepts_panel')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      partial.dispose();
      await tester.pump();
    },
  );
}
