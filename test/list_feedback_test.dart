import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/features/review/application/list_feedback_service.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';
import 'package:health_anki_flutter/features/review/data/list_feedback_api.dart';
import 'package:health_anki_flutter/features/review/domain/list_feedback.dart';
import 'package:health_anki_flutter/features/review/domain/stats_models.dart';

import 'support/list_feedback_fixture.dart';

class _Store extends LocalReviewStore {
  String? owner = 'synthetic-owner-a';
  List<Map<String, dynamic>> pending = [];
  List<Map<String, dynamic>> cached = [];
  bool unavailable = false;

  @override
  String? get activeOwnerScope => owner;

  @override
  Future<List<Map<String, dynamic>>> flagOutbox({String? ownerScope}) async {
    if (unavailable) throw StateError('Synthetic unavailable storage');
    return [...pending];
  }

  @override
  Future<List<Map<String, dynamic>>> likedFlags({String? ownerScope}) async {
    if (unavailable) throw StateError('Synthetic unavailable storage');
    return cached;
  }
}

Map<String, dynamic> _flag(int card, String reason, {String? guid}) => {
  'card_id': card,
  'guid': guid ?? 'synthetic-note-$card',
  'reason': reason,
  'client_id': 'synthetic-event-$card-$reason',
};

void main() {
  test('synthetic metadata transport returns an empty snapshot', () async {
    expect(await ListFeedbackFixtureApi().fetchListFeedbackFlags(), isEmpty);
  });

  const tags = {
    'synthetic-note-1': 'node::a node::a node::b node::none node::',
    'synthetic-note-2': 'node::a',
    'synthetic-note-3': 'node::deleted',
    'synthetic-note-4': 'node::wrong',
  };

  test('metadata maps both feedback kinds without conflating other flags', () {
    final result = ListFeedback.byNode(
      flags: [
        _flag(1, 'like'),
        _flag(1, 'like'),
        _flag(2, 'dislike'),
        _flag(3, 'delete'),
        _flag(4, 'wrong'),
        _flag(5, 'like'), // Unmapped notes have no invented association.
      ],
      noteTags: tags,
    );
    expect(result.keys, unorderedEquals(['a', 'b']));
    expect(result['a']!.liked, isTrue);
    expect(result['a']!.disliked, isTrue);
    expect(result['b']!.liked, isTrue);
    expect(result['b']!.disliked, isFalse);
  });

  test('legacy cached IDs map only through existing review identities', () {
    final result = ListFeedback.byNode(
      flags: [
        {'card_id': 1, 'reason': 'like'},
        {'card_id': 99, 'reason': 'dislike'},
      ],
      noteTags: tags,
      reviewLog: [
        ReviewLogEntry(
          cardId: 1,
          guid: 'synthetic-note-1',
          at: DateTime.utc(2026, 10, 24),
          rating: 3,
        ),
      ],
    );
    expect(result.keys, unorderedEquals(['a', 'b']));
    expect(result['a']!.liked, isTrue);
    expect(result['a']!.disliked, isFalse);
  });

  test(
    'pending actions overlay the server, including reasonless hide Undo',
    () async {
      final api = ListFeedbackFixtureApi()
        ..flags = [_flag(1, 'like'), _flag(2, 'dislike')];
      final store = _Store()
        ..pending = [
          {
            'op': 'dismiss',
            'reason': 'like',
            'card_id': 1,
            'client_id': 'synthetic-event-1-like',
            'like_client_ids': ['synthetic-event-1-like'],
          },
          {
            'op': 'dismiss',
            'card_id': 2,
            'client_id': 'synthetic-event-2-dislike',
          },
          _flag(3, 'like'),
          _flag(4, 'dislike'),
        ];
      final result = await ListFeedbackService(
        api: api,
        store: store,
      ).load(noteTags: tags);
      expect(result.keys, unorderedEquals(['deleted', 'wrong']));
      expect(result['deleted']!.liked, isTrue);
      expect(result['wrong']!.disliked, isTrue);
    },
  );

  test('withdrawal preserves another open flag on the same card', () async {
    final api = ListFeedbackFixtureApi()
      ..flags = [
        _flag(1, 'like'),
        {..._flag(1, 'like'), 'client_id': 'synthetic-other-device-like'},
      ];
    final store = _Store()
      ..pending = [
        {'op': 'dismiss', 'card_id': 1, 'client_id': 'synthetic-event-1-like'},
      ];
    final result = await ListFeedbackService(
      api: api,
      store: store,
    ).load(noteTags: tags);
    expect(result['a']!.liked, isTrue);
  });

  test(
    'captures pending flags before an in-flight server ACK drains them',
    () async {
      final store = _Store()..pending = [_flag(1, 'like')];
      final api = ListFeedbackFixtureApi()
        ..beforeRead = () async => store.pending.clear();
      final result = await ListFeedbackService(
        api: api,
        store: store,
      ).load(noteTags: tags);
      expect(store.pending, isEmpty);
      expect(result['a']!.liked, isTrue);
    },
  );

  test(
    'offline load uses cached likes and pending dislikes without hidden IDs',
    () async {
      final store = _Store()
        ..cached = [_flag(1, 'like')]
        ..pending = [_flag(2, 'dislike'), _flag(3, 'delete')];
      final result = await ListFeedbackService(
        api: ListFeedbackFixtureApi()..unavailable = true,
        store: store,
      ).load(noteTags: tags);
      expect(result['a']!.liked, isTrue);
      expect(result['a']!.disliked, isTrue);
      expect(result.containsKey('deleted'), isFalse);
    },
  );

  test('server success replaces stale cached likes', () async {
    final result = await ListFeedbackService(
      api: ListFeedbackFixtureApi(),
      store: _Store()..cached = [_flag(1, 'like')],
    ).load(noteTags: tags);
    expect(result, isEmpty);
  });

  test('unavailable feedback and storage leave reading usable', () async {
    final result = await ListFeedbackService(
      api: ListFeedbackFixtureApi()..unavailable = true,
      store: _Store()..unavailable = true,
    ).load(noteTags: tags);
    expect(result, isEmpty);
  });

  test('account switch discards an in-flight feedback result', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final api = ListFeedbackFixtureApi()
      ..flags = [_flag(1, 'like')]
      ..beforeRead = () async {
        started.complete();
        await release.future;
      };
    final store = _Store();
    final loading = ListFeedbackService(
      api: api,
      store: store,
    ).load(noteTags: tags);
    await started.future;
    store.owner = 'synthetic-owner-b';
    release.complete();
    expect(await loading, isEmpty);
  });
}
