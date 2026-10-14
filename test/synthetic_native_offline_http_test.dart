// Integrate as test/synthetic_native_offline_http_test.dart in parent checkout.
// Only generated inputs, MockClient handlers and byte-array process identities.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../tool/fixtures/synthetic_native_offline_restart_main.dart';
import '../tool/fixtures/synthetic_recall_flow.dart';

SyntheticNativeOfflineHttp fixture() => SyntheticNativeOfflineHttp(
  List.generate(20, (i) => syntheticCard(i + 1)),
  'invented-owner-hash',
);
http.Request review({
  String event = 'invented-event-E1',
  int card = 1,
  int rating = 3,
}) =>
    http.Request(
        'POST',
        Uri.parse('https://recall-bench.invalid/rest/v1/rpc/apply_review'),
      )
      ..body = jsonEncode({
        'p_client_event_id': event,
        'p_card_id': card,
        'p_guid': 'synthetic-card-1',
        'p_rating': rating,
      });

void main() {
  test('native guard accepts only exact owned process before first NUL', () {
    expect(
      syntheticNativeProcessIdentity(
        utf8.encode('com.german.recall.syntheticbenchmark\u0000'),
      ),
      isTrue,
    );
    expect(
      syntheticNativeProcessIdentity(
        utf8.encode('com.german.recall.syntheticbenchmark\u0000ignored'),
      ),
      isTrue,
    );
    for (final value in [
      'com.german.health_anki_flutter\u0000',
      'com.german.recall.syntheticbenchmark:foreign\u0000',
      'com.german.recall.syntheticbenchmark',
      '\u0000',
    ]) {
      expect(syntheticNativeProcessIdentity(utf8.encode(value)), isFalse);
    }
    expect(syntheticNativeProcessIdentity([255, 0]), isFalse);
    expect(syntheticNativeProcessIdentity(List.filled(129, 0)), isFalse);
  });
  test('offline RPC keeps acceptance empty', () async {
    final f = fixture();
    expect((await f.respond(review())).statusCode, 503);
    expect(f.offlineAttempts, 1);
    expect(f.onlineAttempts, 0);
    expect(f.accepted, isEmpty);
  });
  test('lost ACK followed by identical event yields one acceptance and two attempts', () async {
    final f = fixture()
      ..onlineWrites = true
      ..loseNextAck = true;
    final first = await f.respond(review());
    expect(first.statusCode, 503);
    expect(f.accepted, {'invented-event-E1': 9001});
    final second = await f.respond(review());
    expect(second.statusCode, 200);
    expect(jsonDecode(second.body), 9001);
    expect(f.onlineAttempts, 2);
    expect(f.accepted.length, 1);
    expect(f.receivedHashes, [
      f.eventHash('invented-event-E1'),
      f.eventHash('invented-event-E1'),
    ]);
  });
  test('retry may reorder JSON keys but cannot change its payload', () async {
    final f = fixture()
      ..onlineWrites = true
      ..loseNextAck = true;
    await f.respond(review());
    final reordered = review()
      ..body = jsonEncode({
        'p_rating': 3,
        'p_guid': 'synthetic-card-1',
        'p_card_id': 1,
        'p_client_event_id': 'invented-event-E1',
      });
    expect((await f.respond(reordered)).statusCode, 200);
    await expectLater(f.respond(review(rating: 1)), throwsStateError);
    expect(f.accepted.length, 1);
  });
  test('empty event and wrong card are refused before acceptance', () async {
    final f = fixture()..onlineWrites = true;
    await expectLater(f.respond(review(event: '')), throwsStateError);
    await expectLater(f.respond(review(card: 2)), throwsStateError);
    expect(f.accepted, isEmpty);
  });
  test('fixture refuses HTTP, credentials and outside origin', () async {
    final f = fixture();
    for (final uri in [
      'http://recall-bench.invalid/rest/v1/decks',
      'https://token@recall-bench.invalid/rest/v1/decks',
      'https://outside.invalid/rest/v1/decks',
      'https://recall-bench.invalid:444/rest/v1/decks',
    ]) {
      await expectLater(
        f.respond(http.Request('GET', Uri.parse(uri))),
        throwsStateError,
      );
    }
  });
  test('restored offline read is refused through mock only', () async {
    final f = fixture()..offlineReads = true;
    await expectLater(
      f.respond(
        http.Request(
          'GET',
          Uri.parse(
            'https://recall-bench.invalid/rest/v1/decks?select=deck_id,name',
          ),
        ),
      ),
      throwsA(isA<http.ClientException>()),
    );
    expect(f.accepted, isEmpty);
  });
  test('accepted card is absent from due rows and count', () async {
    final f = fixture()..onlineWrites = true;
    await f.respond(review());
    final uri = Uri.https('recall-bench.invalid', '/rest/v1/cards', {
      'select': '*',
      'deleted': 'eq.false',
      'suspended': 'eq.false',
      'state': 'neq.0',
      'order': 'due.asc.nullslast,id.asc.nullslast',
      'notes.deck_id': 'eq.1',
    });
    final rows =
        jsonDecode((await f.respond(http.Request('GET', uri))).body) as List;
    expect(rows.length, 19);
    expect(rows.first['id'], 2);
    expect(rows.any((row) => row['id'] == 1), isFalse);
    final count = await f.respond(
      http.Request(
        'POST',
        Uri.parse('https://recall-bench.invalid/rest/v1/rpc/deck_counts'),
      ),
    );
    expect(jsonDecode(count.body), [
      {'deck_id': 1, 'due': 19, 'new': 0},
    ]);
  });
}
