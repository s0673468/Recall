import 'stats_models.dart';
import 'inline_html.dart';

/// Pure layout for a Read-tab primer body with inline extra figures.
///
/// The multi-figure contract (migration 009) numbers a primer's paragraphs by
/// splitting `body_html` on `<br>\s*<br>` (case-insensitive) only at top level,
/// i.e. where no `<b>`/`<i>`/`<u>`/`<code>`/`<ul>`/`<ol>`/`<li>` is open.
/// Paragraphs are numbered from 1 and every split piece counts, including an
/// empty trailing one, so the numbering matches METIS's publishing checks.

const _pairedTags = {'b', 'i', 'u', 'code', 'ul', 'ol', 'li'};

// The separator alternative comes first so `<br><br>` is consumed as one
// break rather than two `<br>` tags.
final _tokenRe = RegExp(
  r'(<br>\s*<br>)|<\s*(/?)\s*([a-zA-Z0-9]+)(?:\s+[^>]*)?>',
  caseSensitive: false,
);

/// The top-level paragraphs of [html] and the exact separator text between
/// each consecutive pair (`separators.length == paragraphs.length - 1`).
({List<String> paragraphs, List<String> separators}) _split(String html) {
  final paragraphs = <String>[];
  final separators = <String>[];
  final open = <String, int>{};
  var openCount = 0;
  var start = 0;
  for (final match in _tokenRe.allMatches(html)) {
    final separator = match.group(1);
    if (separator != null) {
      if (openCount == 0) {
        paragraphs.add(html.substring(start, match.start));
        separators.add(separator);
        start = match.end;
      }
      continue;
    }
    final tag = match.group(3)!.toLowerCase();
    if (!_pairedTags.contains(tag)) continue;
    if (match.group(2)!.isEmpty) {
      open[tag] = (open[tag] ?? 0) + 1;
      openCount++;
    } else if ((open[tag] ?? 0) > 0) {
      // A stray closing tag never makes the depth negative.
      open[tag] = open[tag]! - 1;
      openCount--;
    }
  }
  paragraphs.add(html.substring(start));
  return (paragraphs: paragraphs, separators: separators);
}

/// The top-level paragraphs of [html], in order (always at least one).
List<String> splitTopLevelParagraphs(String html) => _split(html).paragraphs;

/// One piece of a laid-out primer body.
sealed class PrimerBlock {
  const PrimerBlock();
}

/// A run of consecutive paragraphs, rejoined with their original separators.
final class PrimerTextBlock extends PrimerBlock {
  final String html;
  final String? heading;
  final int? paragraphNumber;
  const PrimerTextBlock(this.html, {this.heading, this.paragraphNumber});
}

/// An extra figure; [index] is its position in [ConceptPage.extraFigures].
final class PrimerFigureBlock extends PrimerBlock {
  final int index;
  final ConceptExtraFigure figure;
  const PrimerFigureBlock(this.index, this.figure);
}

/// Interleaves [figures] with [bodyHtml]: a figure with `afterParagraph = k`
/// follows paragraph k; `k` at or beyond the paragraph count, or null, puts it
/// after the body. Figures sharing a slot keep their list order.
///
/// Paragraphs between two figure slots stay together in one text block with
/// their original separators, so the text renders exactly as before. Without
/// figures the result is the whole body as a single text block. With [sections],
/// two or more recognized openers also start separate blocks carrying a heading
/// and the original paragraph number. Fewer openers retain the legacy layout.
/// Blank text blocks (e.g. an empty trailing paragraph) are dropped.
List<PrimerBlock> layoutPrimerBody(
  String bodyHtml,
  List<ConceptExtraFigure> figures, {
  bool sections = false,
}) {
  final (:paragraphs, :separators) = _split(bodyHtml);
  final openings = sections
      ? paragraphs.map(primerSectionOpening).toList()
      : <({String heading, String html})?>[];
  final useSections = openings.where((opening) => opening != null).length >= 2;
  if (figures.isEmpty && !useSections) return [PrimerTextBlock(bodyHtml)];
  final count = paragraphs.length;
  final slots = <int, List<PrimerFigureBlock>>{};
  for (var i = 0; i < figures.length; i++) {
    final after = figures[i].afterParagraph;
    final slot = after == null || after > count ? count : after;
    (slots[slot] ??= []).add(PrimerFigureBlock(i, figures[i]));
  }

  final blocks = <PrimerBlock>[];
  final buffer = StringBuffer();
  String? heading;
  int? paragraphNumber;
  void flush() {
    final text = buffer.toString();
    buffer.clear();
    if (text.trim().isNotEmpty || heading != null) {
      blocks.add(
        PrimerTextBlock(
          text,
          heading: heading,
          paragraphNumber: paragraphNumber,
        ),
      );
    }
    heading = null;
    paragraphNumber = null;
  }

  for (var p = 1; p <= count; p++) {
    final opening = useSections ? openings[p - 1] : null;
    if (opening != null) {
      flush();
      heading = opening.heading;
      paragraphNumber = p;
    }
    buffer.write(opening?.html ?? paragraphs[p - 1]);
    final here = slots[p];
    if (here != null) {
      flush();
      blocks.addAll(here);
    } else if (p < count) {
      buffer.write(separators[p - 1]);
    }
  }
  flush();
  return blocks;
}

const _sectionLabels = {
  'In short.',
  'Picture it.',
  'How it works.',
  'The formula.',
  'Worked example.',
  'Compare.',
  'Watch out.',
  "Where you'll meet it.",
};
final _sectionLead = RegExp(r'^\s*<b>([^<]+)</b>');

/// Recognizes only the agreed leading labels; the stored paragraph is untouched.
({String heading, String html})? primerSectionOpening(String paragraph) {
  final match = _sectionLead.firstMatch(paragraph);
  if (match == null) return null;
  final label = decodeEntities(match.group(1)!).replaceAll('’', "'");
  if (!_sectionLabels.contains(label)) return null;
  return (
    heading: label.substring(0, label.length - 1),
    html: paragraph.substring(match.end).trimLeft(),
  );
}
