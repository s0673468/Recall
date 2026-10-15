import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../tool/fixtures/synthetic_recall_flow.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('synthetic load then explicit deck selection stays online', () async {
    final previousPlatform = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    SyntheticRecallFlow? flow;
    addTearDown(() async {
      try {
        await flow?.close();
      } finally {
        SharedPreferencesStorePlatform.instance = previousPlatform;
        SharedPreferences.resetStatic();
      }
    });
    final session = await SyntheticRecallFlow.create(
      cardCount: 20,
      seededOutbox: 0,
      warmCache: false,
    );
    flow = session;
    await session.load();
    expect(session.controller.state.loading, isFalse);
    expect(session.controller.state.offline, isFalse);
    expect(session.controller.state.error, isNull);
    final dueRequestsBefore = session.httpFixture.counts['cards_due']!;
    final newRequestsBefore = session.httpFixture.counts['cards_new']!;

    // This invokes production selectDeck -> load(deckId: 1) -> RecallApi,
    // whose concrete deck filter is eq.1 rather than the automatic in.(1).
    await session.selectDeck(1);
    expect(session.controller.state.deckFilter, 1);
    expect(session.controller.state.loading, isFalse);
    expect(session.controller.state.offline, isFalse);
    expect(session.controller.state.error, isNull);
    expect(session.controller.state.queue, hasLength(20));
    expect(session.controller.state.current?.id, 1);
    expect(
      session.httpFixture.counts['cards_due'],
      greaterThan(dueRequestsBefore),
    );
    expect(
      session.httpFixture.counts['cards_new'],
      greaterThan(newRequestsBefore),
    );

    await session.rateFirstGood();
    expect(session.controller.state.current?.id, 2);
    final pending = await session.store.outbox();
    expect(pending, hasLength(1));
    expect(pending.single['card_id'], 1);
  });

  for (final filter in ['eq.1', 'in.(1)']) {
    for (final state in ['neq.0', 'eq.0']) {
      test('synthetic fixture permits deck1 $filter $state', () async {
        final fixture = SyntheticRecallHttp([syntheticCard(1)]);
        final request = http.Request(
          'GET',
          Uri.https('recall-bench.invalid', '/rest/v1/cards', {
            'select': 'id',
            'deleted': 'eq.false',
            'suspended': 'eq.false',
            'state': state,
            'order': 'due.asc.nullslast,id.asc.nullslast',
            'notes.deck_id': filter,
          }),
        );
        expect((await fixture.respond(request)).statusCode, 200);
      });
    }
  }

  for (final filter in ['eq.2', 'in.(2)', 'in.(1,2)', 'eq.1.extra', '']) {
    for (final state in ['neq.0', 'eq.0']) {
      test(
        'synthetic fixture refuses nonfixture filter $filter $state',
        () async {
          final fixture = SyntheticRecallHttp([syntheticCard(1)]);
          final request = http.Request(
            'GET',
            Uri.https('recall-bench.invalid', '/rest/v1/cards', {
              'select': 'id',
              'deleted': 'eq.false',
              'suspended': 'eq.false',
              'state': state,
              'order': 'due.asc.nullslast,id.asc.nullslast',
              if (filter.isNotEmpty) 'notes.deck_id': filter,
            }),
          );
          await expectLater(fixture.respond(request), throwsStateError);
          expect(fixture.totalRequests, 0);
        },
      );
    }
  }
}
