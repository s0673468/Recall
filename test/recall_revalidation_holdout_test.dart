// Independent campaign holdout. The expected model intentionally does not use
// RecallApi's pagination constants or its marker/acknowledgement helpers.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/review/domain/content_revalidation.dart';

final _revision = DateTime.utc(2031, 2, 3, 4, 5, 6);
const _firstId = 930001;
const _marker = 'content_revalidate::20310203T040506Z';
const _laterMarker = 'content_revalidate::20310204T040506Z';

class _HeldCard {
  final Map<String, dynamic> row;
  // Independently authored truth, not obtained by parsing production tags.
  final DateTime? revision;

  _HeldCard(
    int id, {
    String? tags = _marker,
    DateTime? revision,
    int deck = 7,
    int reps = 19,
    int state = 2,
    bool deleted = false,
    bool suspended = false,
    bool dueNow = false,
    bool longText = false,
  }) : revision = revision ?? (tags == _marker ? _revision : null),
       row = {
         'id': id,
         'guid': 'heldout-$id',
         'deleted': deleted,
         'suspended': suspended,
         'stability': 38.125 + (id % 7),
         'difficulty': 3.625 + (id % 3),
         'due': dueNow ? '2001-01-02T03:04:05Z' : '2034-06-07T08:09:10Z',
         'state': state,
         'reps': reps,
         'lapses': id % 4,
         'last_review': '2030-12-20T10:11:12Z',
         'cloud_seen': id.isEven,
         'notes': {
           // Invented ASCII content: typical combined size 198, maximum 629.
           'front': List.filled(longText ? 309 : 94, 'f').join(),
           'back': List.filled(longText ? 320 : 104, 'b').join(),
           'has_latex': id.isEven,
           'deck_id': deck,
           'latex_svg': id.isEven ? '<svg>heldout-$id</svg>' : null,
           'tags': tags,
         },
       };

  int get id => row['id'] as int;
  int get deck => (row['notes'] as Map)['deck_id'] as int;
  String? get tags => (row['notes'] as Map)['tags'] as String?;
}

Map<String, dynamic> _log(int id, int rating, DateTime at) => {
  'card_id': id,
  'rating': rating,
  'rating_at': at.toIso8601String(),
};

List<_HeldCard> _expected(
  List<_HeldCard> cards,
  List<Map<String, dynamic>> logs, {
  int limit = 20,
  int? deck,
  Set<int>? included,
  Set<int> hidden = const {},
}) {
  if (deck == null && included != null && included.isEmpty) return [];
  final wanted = limit < 0 ? 0 : (limit > 20 ? 20 : limit);
  final marked = cards.where((card) {
    return card.row['deleted'] == false &&
        card.row['suspended'] == false &&
        (card.row['reps'] as int) > 0 &&
        (card.tags?.contains('content_revalidate::') ?? false) &&
        (deck == null ? (included?.contains(card.deck) ?? true) : card.deck == deck);
  }).toList()..sort((a, b) => a.id.compareTo(b.id));
  return marked.take(5000).where((card) {
    final revision = card.revision;
    if (revision == null || hidden.contains(card.id)) return false;
    return !logs.any((log) {
      final rating = log['rating'];
      final at = DateTime.tryParse(log['rating_at'] as String? ?? '');
      return log['card_id'] == card.id &&
          const {2, 3, 4}.contains(rating) &&
          at != null &&
          at.isAfter(revision);
    });
  }).take(wanted).toList();
}

dynamic _field(Map<String, dynamic> row, String path) {
  dynamic value = row;
  for (final part in path.split('.')) {
    if (value is! Map) return null;
    value = value[part];
  }
  return value;
}

int _compare(dynamic a, dynamic b) {
  if (a == b) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  if (a is num && b is num) return a.compareTo(b);
  final left = '$a';
  final right = '$b';
  final leftTime = DateTime.tryParse(left);
  final rightTime = DateTime.tryParse(right);
  if (leftTime != null && rightTime != null) return leftTime.compareTo(rightTime);
  return left.compareTo(right);
}

List<String> _splitTerms(String text) {
  final result = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == '(') depth++;
    if (text[i] == ')') depth--;
    if (text[i] == ',' && depth == 0) {
      result.add(text.substring(start, i));
      start = i + 1;
    }
  }
  result.add(text.substring(start));
  return result;
}

bool _matches(dynamic actual, String filter) {
  if (filter.startsWith('not.')) return !_matches(actual, filter.substring(4));
  final dot = filter.indexOf('.');
  if (dot < 0) throw StateError('Unsupported holdout filter: $filter');
  final op = filter.substring(0, dot);
  final raw = filter.substring(dot + 1);
  if (op == 'in') {
    final choices = raw.substring(1, raw.length - 1).split(',');
    return choices.contains('$actual');
  }
  if (op == 'like') {
    final pattern = RegExp.escape(raw).replaceAll('%', '.*').replaceAll('_', '.');
    return actual is String && RegExp('^$pattern\$').hasMatch(actual);
  }
  dynamic expected = raw;
  if (actual is num) expected = num.parse(raw);
  if (actual is bool) expected = raw == 'true';
  final comparison = _compare(actual, expected);
  return switch (op) {
    'eq' => comparison == 0,
    'neq' => comparison != 0,
    'gt' => comparison > 0,
    'gte' => comparison >= 0,
    'lt' => comparison < 0,
    'lte' => comparison <= 0,
    _ => throw StateError('Unsupported holdout operator: $op'),
  };
}

bool _expression(Map<String, dynamic> row, String expression) {
  if (expression.startsWith('and(') || expression.startsWith('or(')) {
    final isAnd = expression.startsWith('and(');
    final inner = expression.substring(isAnd ? 4 : 3, expression.length - 1);
    final values = _splitTerms(inner).map((term) => _expression(row, term));
    return isAnd ? values.every((value) => value) : values.any((value) => value);
  }
  final match = RegExp(r'^(.+?)\.(eq|neq|gt|gte|lt|lte|in|like|not)\.(.*)$')
      .firstMatch(expression);
  if (match == null) throw StateError('Unsupported holdout expression: $expression');
  return _matches(_field(row, match.group(1)!), '${match.group(2)}.${match.group(3)}');
}

// A deliberately small PostgREST model. It filters BEFORE ordering/pagination,
// honors both Range and offset/limit, and never fabricates a full requested page.
class _Server {
  final List<_HeldCard> cards;
  final List<Map<String, dynamic>> logs;
  final int cardCap;
  final int logCap;
  final requests = <http.Request>[];
  int markedRowsDelivered = 0;
  String? failLane;
  bool interrupted = false;

  _Server(this.cards, this.logs, {this.cardCap = 10000, this.logCap = 10000});

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (request.method != 'GET') throw StateError('Discovery attempted a write');
    final q = request.url.queryParameters;
    final isCards = request.url.path.endsWith('/cards');
    final isLogs = request.url.path.endsWith('/review_log');
    final markerRead = isCards && q.containsKey('notes.tags');
    final ackRead = isLogs && q.containsKey('rating');
    if ((failLane == 'cards' && markerRead) || (failLane == 'logs' && ackRead)) {
      if (interrupted) throw StateError('Synthetic interrupted lane read');
      return http.Response(
        jsonEncode({'code': 'HOLDOUT', 'message': 'Synthetic lane unavailable'}),
        400,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    }
    if (!isCards && !isLogs) throw StateError('Unexpected holdout endpoint');
    // v3 instrumentation correction: compute this per request so card/deck
    // mutations remain fresh; preserve the original first-match semantics.
    final deckByCardId = <int, int>{};
    if (isLogs) {
      for (final card in cards) {
        deckByCardId.putIfAbsent(card.id, () => card.deck);
      }
    }
    var rows = isCards
        ? cards.map((card) => card.row).toList()
        : logs.map((log) {
            final deck = deckByCardId[log['card_id']];
            return <String, dynamic>{
              ...log,
              if (deck != null)
                'cards': {'notes': {'deck_id': deck}},
            };
          }).toList();
    for (final entry in request.url.queryParametersAll.entries) {
      if (const {'select', 'order', 'limit', 'offset'}.contains(entry.key)) continue;
      for (final filter in entry.value) {
        if (entry.key == 'or' || entry.key == 'and') {
          rows = rows.where((row) => _expression(row, '${entry.key}$filter')).toList();
        } else {
          rows = rows.where((row) => _matches(_field(row, entry.key), filter)).toList();
        }
      }
    }
    final order = q['order'];
    if (order != null) {
      final terms = order.split(',');
      // Stabilize exact timestamp ties by fixture insertion order, without
      // inventing unique review-log timestamps or deduplicating the server.
      final positions = <Map<String, dynamic>, int>{
        for (var i = 0; i < rows.length; i++) rows[i]: i,
      };
      rows.sort((a, b) {
        for (final term in terms) {
          final parts = term.split('.');
          final comparison = _compare(_field(a, parts.first), _field(b, parts.first));
          if (comparison != 0) return parts.contains('desc') ? -comparison : comparison;
        }
        return positions[a]!.compareTo(positions[b]!);
      });
    }
    var offset = int.parse(q['offset'] ?? '0');
    var count = int.tryParse(q['limit'] ?? '') ?? rows.length;
    final range = request.headers['range'];
    if (range != null) {
      final parts = range.replaceFirst('items=', '').split('-');
      offset = int.parse(parts.first);
      if (parts.length > 1 && parts[1].isNotEmpty) {
        count = int.parse(parts[1]) - offset + 1;
      }
    }
    final cap = isCards ? cardCap : logCap;
    if (count > cap) count = cap;
    final page = rows.skip(offset).take(count).toList();
    if (markerRead) markedRowsDelivered += page.length;
    final wantsCount = request.headers['prefer']?.contains('count=exact') ?? false;
    final total = wantsCount ? '${rows.length}' : '*';
    final contentRange = page.isEmpty ? '*/$total' : '$offset-${offset + page.length - 1}/$total';
    return http.Response(
      jsonEncode(page),
      200,
      request: request,
      headers: {'content-type': 'application/json', 'content-range': contentRange},
    );
  }

  RecallApi api() {
    final client = SupabaseClient(
      'https://heldout.invalid',
      'synthetic-anon-key',
      httpClient: MockClient(handle),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    return RecallApi(client);
  }
}

void _expectCards(List<ReviewCard> actual, List<_HeldCard> expected) {
  expect(actual.map((card) => card.id).toList(), expected.map((card) => card.id).toList());
  for (var i = 0; i < actual.length; i++) {
    final card = actual[i];
    final row = expected[i].row;
    final note = row['notes'] as Map;
    expect(card.toJson(), {
      'id': row['id'],
      'guid': row['guid'],
      'deck_id': note['deck_id'],
      'front': note['front'],
      'back': note['back'],
      'has_latex': note['has_latex'],
      'stability': row['stability'],
      'difficulty': row['difficulty'],
      'due': DateTime.parse(row['due'] as String).toUtc().toIso8601String(),
      'state': row['state'],
      'reps': row['reps'],
      'lapses': row['lapses'],
      'last_review': DateTime.parse(row['last_review'] as String).toUtc().toIso8601String(),
      'cloud_seen': row['cloud_seen'],
      if (note['tags'] != null) 'tags': note['tags'],
      if (note['latex_svg'] != null) 'latex_svg': note['latex_svg'],
      'content_revalidation_pending': true,
    });
  }
}

void _expectReadOnlyBounded(_Server server) {
  expect(server.requests.every((request) => request.method == 'GET'), isTrue);
  expect(server.markedRowsDelivered, lessThanOrEqualTo(5000));
  for (final request in server.requests.where((request) =>
      request.url.path.endsWith('/review_log') &&
      request.url.queryParameters.containsKey('rating'))) {
    expect(request.url.queryParameters['card_id'], isNotNull);
    expect(request.url.queryParameters['rating_at'], isNotNull);
  }
}

void main() {
  test('holdout server honors ID/time/rating filters, Range and server caps', () async {
    final server = _Server([], [
      _log(_firstId, 1, _revision.add(const Duration(seconds: 1))),
      _log(_firstId, 2, _revision),
      _log(_firstId, 3, _revision.add(const Duration(seconds: 1))),
      _log(_firstId, 4, _revision.add(const Duration(seconds: 2))),
      _log(_firstId + 1, 3, _revision.add(const Duration(seconds: 3))),
    ], logCap: 1);
    final request = http.Request('GET', Uri.https('heldout.invalid', '/rest/v1/review_log', {
      'card_id': 'in.($_firstId)',
      'rating': 'gt.1',
      'rating_at': 'gt.${_revision.toIso8601String()}',
      'order': 'rating_at.asc',
      'offset': '1',
      'limit': '50',
    }));
    final response = await server.handle(request);
    expect((jsonDecode(response.body) as List).single['rating'], 4);
    request.headers['range'] = '0-49';
    final ranged = await server.handle(request);
    expect((jsonDecode(ranged.body) as List).single['rating'], 3);
  });

  test('strict newest marker truth includes invalid newer lookalikes', () {
    final cases = <String?, DateTime?>{
      null: null,
      'wording_only topic': null,
      'content_revalidate::20310230T040506Z': null,
      'content_revalidate::20310203T240506Z': null,
      'content_revalidate::20310203T040560Z': null,
      'content_revalidate::20310203T040506z': null,
      'content_revalidate::20310203T040506+0000': null,
      'prefix$_marker': null,
      '${_marker}suffix': null,
      '$_marker content_revalidate::20319999T999999Z': _revision,
      '$_laterMarker\t$_marker\n$_laterMarker content_revalidate::20990230T040506Z':
          DateTime.utc(2031, 2, 4, 4, 5, 6),
      'content_revalidate::20320229T010203Z': DateTime.utc(2032, 2, 29, 1, 2, 3),
    };
    for (final entry in cases.entries) {
      expect(contentRevalidationRevision(entry.key), entry.value, reason: '${entry.key}');
    }
  });

  test('ratings and strict time boundaries preserve the whole card snapshot', () async {
    final cards = [for (var i = 0; i < 9; i++) _HeldCard(_firstId + i, longText: i == 0)];
    cards[7] = _HeldCard(_firstId + 7, tags: '$_marker $_laterMarker',
        revision: _revision.add(const Duration(days: 1)));
    cards[8] = _HeldCard(_firstId + 8, tags: 'content_revalidate::20310230T040506Z');
    final logs = [
      _log(_firstId, 1, _revision.add(const Duration(days: 2))),
      _log(_firstId + 1, 2, _revision),
      _log(_firstId + 2, 2, _revision.subtract(const Duration(microseconds: 1))),
      _log(_firstId + 3, 2, _revision.add(const Duration(microseconds: 1))),
      _log(_firstId + 4, 3, _revision.add(const Duration(seconds: 1))),
      _log(_firstId + 5, 4, _revision.add(const Duration(seconds: 1))),
      _log(_firstId + 7, 4, _revision.add(const Duration(hours: 1))),
      _log(_firstId + 3, 2, _revision.add(const Duration(microseconds: 1))),
    ];
    final server = _Server(cards.reversed.toList(), logs.reversed.toList());
    _expectCards(await server.api().fetchContentRevalidationQueue(), _expected(cards, logs));
    _expectReadOnlyBounded(server);
  });

  test('hidden, deleted, suspended, unstudied and automatic deck scope', () async {
    final cards = [
      _HeldCard(_firstId),
      _HeldCard(_firstId + 1, deleted: true),
      _HeldCard(_firstId + 2, suspended: true),
      _HeldCard(_firstId + 3, reps: 0, state: 0),
      _HeldCard(_firstId + 4, deck: 8),
      _HeldCard(_firstId + 5, deck: 9),
      _HeldCard(_firstId + 6, deck: 10),
      _HeldCard(_firstId + 7, deck: 11),
      _HeldCard(_firstId + 8),
    ];
    final decks = [
      const DeckRow(deckId: 7, name: 'Science'),
      const DeckRow(deckId: 8, name: 'Opt-in::Synthetic'),
      const DeckRow(deckId: 9, name: 'Portuguese::Synthetic'),
      const DeckRow(deckId: 10, name: 'Experimental::Synthetic'),
      const DeckRow(deckId: 11, name: 'Extra Trees'),
    ];
    expect(automaticReviewDeckIds(decks), {7, 11});
    final server = _Server(cards, []);
    final api = server.api();
    final hidden = {_firstId};
    _expectCards(await api.fetchContentRevalidationQueue(includedDeckIds: {11, 7},
        excludeCardIds: hidden), _expected(cards, [], included: {7, 11}, hidden: hidden));
    _expectCards(await api.fetchContentRevalidationQueue(deckId: 8, includedDeckIds: {}),
        _expected(cards, [], deck: 8, included: {}));
    final before = server.requests.length;
    expect(await api.fetchContentRevalidationQueue(includedDeckIds: {}), isEmpty);
    expect(await api.fetchQueue(includedDeckIds: {}), isEmpty);
    expect(server.requests.length, before);
    _expectReadOnlyBounded(server);
  });

  for (final limit in [-5, 0, 1, 7, 20, 21, 1000]) {
    test('priority cap and limit clamp $limit', () async {
      final cards = [for (var i = 0; i < 31; i++) _HeldCard(_firstId + i)];
      final server = _Server(cards.reversed.toList(), []);
      _expectCards(await server.api().fetchContentRevalidationQueue(limit: limit),
          _expected(cards, [], limit: limit));
      if (limit <= 0) expect(server.requests, isEmpty);
      _expectReadOnlyBounded(server);
    });
  }

  for (final count in [49, 50, 51, 249, 250, 251, 4999, 5000, 5001]) {
    test('last pending candidate at independent scan boundary $count', () async {
      final cards = [for (var i = 0; i < count; i++) _HeldCard(_firstId + i)];
      final logs = [for (var i = 0; i < count - 1; i++)
        _log(_firstId + i, 3, _revision.add(const Duration(seconds: 1)))];
      final server = _Server(cards, logs);
      _expectCards(await server.api().fetchContentRevalidationQueue(), _expected(cards, logs));
      _expectReadOnlyBounded(server);
    });
  }

  for (final cap in [17, 49]) {
    test('short candidate response cap $cap does not mean end of scan', () async {
      final cards = [for (var i = 0; i < 251; i++) _HeldCard(_firstId + i)];
      final logs = [for (var i = 0; i < 250; i++)
        _log(_firstId + i, 4, _revision.add(const Duration(seconds: 1)))];
      final server = _Server(cards, logs, cardCap: cap);
      _expectCards(await server.api().fetchContentRevalidationQueue(), _expected(cards, logs));
      _expectReadOnlyBounded(server);
    });
  }

  // v2 additive holdout: pending rows occupy gaps between possible requested
  // offsets, so continuing with the requested stride cannot silently skip them.
  for (final cap in [17, 49]) {
    test('scattered pending candidates remain complete under server cap $cap', () async {
      const pendingIndices = {31, 73, 127, 190, 250};
      final cards = [for (var i = 0; i < 251; i++) _HeldCard(_firstId + i)];
      final logs = [for (var i = 0; i < 251; i++)
        if (!pendingIndices.contains(i))
          _log(_firstId + i, 3, _revision.add(const Duration(seconds: 1)))];
      final server = _Server(cards, logs, cardCap: cap);
      final actual = await server.api().fetchContentRevalidationQueue();
      _expectCards(actual, _expected(cards, logs));
      expect(actual.map((card) => card.id).toList(), [
        for (final index in [31, 73, 127, 190, 250]) _firstId + index,
      ]);
      _expectReadOnlyBounded(server);
    });
  }

  for (final cap in [17, 49, 250]) {
    test('complete acknowledgement under server cap $cap and repeated history', () async {
      final cards = [
        _HeldCard(_firstId),
        _HeldCard(_firstId + 1, tags: _laterMarker,
            revision: _revision.add(const Duration(days: 1))),
        _HeldCard(_firstId + 2),
      ];
      final logs = [
        for (var i = 0; i < cap * 2 + 3; i++)
          _log(_firstId, 2 + (i % 3), _revision.add(
              i.isEven ? const Duration(hours: 1) : const Duration(days: 10))),
        _log(_firstId + 1, 4, _revision.add(const Duration(days: 2))),
        _log(_firstId + 1, 2, _revision.add(const Duration(hours: 2))),
        _log(_firstId + 2, 1, _revision.add(const Duration(days: 30))),
      ];
      final server = _Server(cards, logs, logCap: cap);
      _expectCards(await server.api().fetchContentRevalidationQueue(), _expected(cards, logs));
      _expectReadOnlyBounded(server);
    });
  }

  test('fresh reads invalidate acknowledgements when the same card is revised', () async {
    final cards = [_HeldCard(_firstId)];
    final logs = <Map<String, dynamic>>[];
    final server = _Server(cards, logs);
    final api = server.api();
    _expectCards(await api.fetchContentRevalidationQueue(), _expected(cards, logs));
    logs.add(_log(_firstId, 3, _revision.add(const Duration(hours: 1))));
    expect(await api.fetchContentRevalidationQueue(), isEmpty);
    cards[0] = _HeldCard(_firstId, tags: _laterMarker,
        revision: _revision.add(const Duration(days: 1)));
    _expectCards(await api.fetchContentRevalidationQueue(), _expected(cards, logs));
    logs.add(_log(_firstId, 2, _revision.add(const Duration(days: 2))));
    expect(await api.fetchContentRevalidationQueue(), isEmpty);
    logs.clear();
    _expectCards(await api.fetchContentRevalidationQueue(), _expected(cards, logs));
    _expectReadOnlyBounded(server);
  });

  test('fetchQueue prepends priority then deduplicates ordinary due and new cards', () async {
    final cards = [
      _HeldCard(_firstId, dueNow: true),
      _HeldCard(_firstId + 1),
      _HeldCard(_firstId + 2, dueNow: true),
      _HeldCard(_firstId + 3, tags: 'wording_only', dueNow: true),
      _HeldCard(_firstId + 4, tags: null, reps: 0, state: 0),
      _HeldCard(_firstId + 5, tags: null, reps: 0, state: 0),
      _HeldCard(_firstId + 6, tags: null, reps: 0, state: 0),
    ];
    final hidden = {_firstId + 2, _firstId + 4};
    final server = _Server(cards.reversed.toList(), []);
    final queue = await server.api().fetchQueue(newLimit: 2, excludeCardIds: hidden);
    expect(queue.map((card) => card.id).toList(), [
      _firstId, _firstId + 1, _firstId + 3, _firstId + 5, _firstId + 6,
    ]);
    expect(queue.map((card) => card.id).toSet().length, queue.length);
    expect(queue.map((card) => card.contentRevalidationPending).toList(),
        [true, true, false, false, false]);
    _expectCards(queue.take(2).toList(), _expected(cards, [], hidden: hidden));
    _expectReadOnlyBounded(server);
  });

  test('twenty priority slots leave remaining due cards in ordinary order', () async {
    final cards = [for (var i = 0; i < 25; i++) _HeldCard(_firstId + i, dueNow: true)];
    final logs = [_log(_firstId + 1, 4, _revision.add(const Duration(seconds: 1)))];
    final priority = _expected(cards, logs);
    final priorityIds = priority.map((card) => card.id).toSet();
    final expectedIds = [
      ...priority.map((card) => card.id),
      ...cards.where((card) => !priorityIds.contains(card.id)).map((card) => card.id),
    ];
    final server = _Server(cards.reversed.toList(), logs);
    final queue = await server.api().fetchQueue(newLimit: 0);
    expect(queue.map((card) => card.id).toList(), expectedIds);
    expect(queue.map((card) => card.id).toSet().length, 25);
    expect(queue.where((card) => card.contentRevalidationPending), hasLength(20));
    expect(queue.skip(20).every((card) => !card.contentRevalidationPending), isTrue);
    _expectCards(queue.take(20).toList(), priority);
    _expectReadOnlyBounded(server);
  });

  for (final lane in ['cards', 'logs']) {
    for (final interrupted in [false, true]) {
      test('optional $lane lane failure/interruption=$interrupted falls back and retries', () async {
        final cards = [
          _HeldCard(_firstId),
          _HeldCard(_firstId + 1, tags: 'wording_only', dueNow: true),
          _HeldCard(_firstId + 2, tags: null, reps: 0, state: 0),
        ];
        final server = _Server(cards, [])
          ..failLane = lane
          ..interrupted = interrupted;
        final api = server.api();
        await expectLater(api.fetchContentRevalidationQueue(), throwsA(anything));
        final fallback = await api.fetchQueue(newLimit: 1);
        expect(fallback.map((card) => card.id).toList(), [_firstId + 1, _firstId + 2]);
        expect(fallback.every((card) => !card.contentRevalidationPending), isTrue);
        server.failLane = null;
        final retry = await api.fetchQueue(newLimit: 1);
        expect(retry.map((card) => card.id).toList(), [_firstId, _firstId + 1, _firstId + 2]);
        expect(retry.first.contentRevalidationPending, isTrue);
        _expectReadOnlyBounded(server);
      });
    }
  }
}
