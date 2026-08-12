/// Contract between the desktop content importer and Recall's study queue.
///
/// A material edit replaces any older marker with one UTC revision marker:
/// `content_revalidate::YYYYMMDDTHHMMSSZ`. Wording-only edits do not add or
/// advance the marker. Recall treats a card as acknowledged only after a
/// successful rating (Hard, Good, or Easy) whose review time is later than the
/// marker; Again deliberately leaves it pending.
const contentRevalidationTagPrefix = 'content_revalidate::';

final RegExp _contentRevalidationTag = RegExp(
  r'^content_revalidate::([0-9]{8}T[0-9]{6}Z)$',
);

/// Return the newest valid material-revision marker in an Anki tag string.
///
/// Invalid dates and lookalike tags are ignored. The importer normally leaves
/// exactly one marker, but choosing the newest keeps older snapshots safe if a
/// partially migrated note temporarily carries more than one.
DateTime? contentRevalidationRevision(String? tags) {
  DateTime? newest;
  for (final tag in (tags ?? '').split(RegExp(r'\s+'))) {
    final match = _contentRevalidationTag.firstMatch(tag);
    if (match == null) continue;
    final stamp = match.group(1)!;
    final parsed = _parseCompactUtc(stamp);
    if (parsed != null && (newest == null || parsed.isAfter(newest))) {
      newest = parsed;
    }
  }
  return newest;
}

bool isSuccessfulContentRevalidationRating(int rating) => rating > 1;

DateTime? _parseCompactUtc(String value) {
  try {
    final parsed = DateTime.utc(
      int.parse(value.substring(0, 4)),
      int.parse(value.substring(4, 6)),
      int.parse(value.substring(6, 8)),
      int.parse(value.substring(9, 11)),
      int.parse(value.substring(11, 13)),
      int.parse(value.substring(13, 15)),
    );
    return _formatCompactUtc(parsed) == value ? parsed : null;
  } on FormatException {
    return null;
  } on RangeError {
    return null;
  }
}

String _formatCompactUtc(DateTime value) {
  String two(int part) => part.toString().padLeft(2, '0');
  final utc = value.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}'
      '${two(utc.month)}${two(utc.day)}T'
      '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
}
