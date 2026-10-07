/// Transport-free production replay probe. This is NOT a counted SQL schedule.
/// Input/output: one JSON object per line; errors are explicit, never passes.
import 'dart:convert';
import 'dart:io';

import '../../lib/features/review/data/review_replay.dart';

void main() async {
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    Object? id;
    try {
      final request = jsonDecode(line) as Map<String, dynamic>;
      id = request['id'];
      final entry = Map<String, dynamic>.from(request['entry'] as Map);
      final server = Map<String, dynamic>.from(request['server'] as Map);
      stdout.writeln(
        jsonEncode({
          'id': id,
          'ok': true,
          'surface': 'production-legacy-merge-helper',
          'countsAsSchedule': false,
          'values': mergeReviewIntoCard(
            server: CardSyncState.fromRow(server),
            entry: entry,
          ),
          'lapsed': reviewLapsed(entry),
        }),
      );
    } catch (error) {
      stdout.writeln(jsonEncode({'id': id, 'ok': false, 'error': '$error'}));
    }
  }
}
