import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/features/review/application/backlog_catch_up.dart';
import 'package:health_anki_flutter/features/review/data/catch_up_state.dart';

final _now = DateTime.utc(2026, 8, 5, 12);

void main() {
  group('CatchUpLocalState deck stream', () {
    test('round-trips the stream that owns the episode', () {
      const state = CatchUpLocalState(
        mode: CatchUpMode.dismissed,
        dayKey: '2026-08-05',
        completedToday: 4,
        deckStream: 'deck:3',
      );
      expect(CatchUpLocalState.fromJson(state.toJson()), state);
    });

    test('reads state saved before streams existed as unscoped', () {
      final state = CatchUpLocalState.fromJson({
        'mode': 'active',
        'day': '2026-08-05',
        'completed_today': 2,
      });
      expect(state.deckStream, isNull);
      expect(state.coversStream('all'), isTrue);
      expect(state.coversStream('deck:3'), isTrue);
      expect(state.toJson().containsKey('deck_stream'), isFalse);
    });

    test('a scoped episode covers only its own stream', () {
      const state = CatchUpLocalState(
        mode: CatchUpMode.active,
        deckStream: 'all',
      );
      expect(state.coversStream('all'), isTrue);
      expect(state.coversStream('deck:2'), isFalse);
    });

    test('day normalization keeps mode and stream, resets progress', () {
      const state = CatchUpLocalState(
        mode: CatchUpMode.active,
        dayKey: '2026-08-04',
        completedToday: 9,
        deckStream: 'deck:1',
      );
      expect(
        BacklogCatchUp.normalizeLocalState(state, _now),
        const CatchUpLocalState(
          mode: CatchUpMode.active,
          dayKey: '2026-08-05',
          deckStream: 'deck:1',
        ),
      );
    });
  });
}
