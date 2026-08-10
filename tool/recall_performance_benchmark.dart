// ignore_for_file: avoid_print

import 'package:health_anki_flutter/features/review/domain/cloze.dart';
import 'package:health_anki_flutter/features/review/domain/inline_html.dart';

const _html = '''
<div><b>What is the </b><span style="color:#5522aa">mitochondria</span>?
  <br><i>It makes energy</i> with \\(E=mc^2\\).</div>
  <ol><li>First item</li><li><code>second</code> item</li></ol>
  <img src="https://example.com/image.png">
''';

const _cloze =
    '<div>Explain {{c1::the {{c2::mitochondria}}::energy organelle}} '
    'with \\(E=mc^2\\).</div>';
const _plain = 'A plain card question with inline \\(E=mc^2\\) and no HTML.';

void main() {
  const iterations = 20000;
  // Warm up the VM and regex JIT before recording timings.
  for (var i = 0; i < 2000; i++) {
    parseInlineHtml(_html);
    parseCloze(_cloze);
  }

  final uncachedHtml = _measure(iterations, () => parseInlineHtml(_html));
  final uncachedPlain = _measure(iterations, () => parseInlineHtml(_plain));
  final uncachedCloze = _measure(iterations, () => parseCloze(_cloze));
  debugClearInlineHtmlCache();
  parseInlineHtmlCached(_html, cacheKey: 'bench:html');
  final cachedHtml = _measure(
    iterations,
    () => parseInlineHtmlCached(_html, cacheKey: 'bench:html'),
  );
  debugClearClozeCache();
  parseClozeCached(_cloze, cacheKey: 'bench:cloze');
  final cachedCloze = _measure(
    iterations,
    () => parseClozeCached(_cloze, cacheKey: 'bench:cloze'),
  );

  print('iterations=$iterations');
  _printResult('inline_html_uncached', iterations, uncachedHtml);
  _printResult('plain_uncached', iterations, uncachedPlain);
  _printResult('cloze_uncached', iterations, uncachedCloze);
  _printResult('inline_html_cached', iterations, cachedHtml);
  _printResult('cloze_cached', iterations, cachedCloze);
}

({int micros, int checksum}) _measure(
  int iterations,
  List<Object> Function() operation,
) {
  var checksum = 0;
  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    checksum += operation().length;
  }
  stopwatch.stop();
  return (micros: stopwatch.elapsedMicroseconds, checksum: checksum);
}

void _printResult(
  String name,
  int iterations,
  ({int micros, int checksum}) result,
) {
  final perOp = result.micros / iterations;
  print(
    '$name total_us=${result.micros} per_op_us=${perOp.toStringAsFixed(2)} '
    'checksum=${result.checksum}',
  );
}
