import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/features/review/domain/stats_models.dart';
import 'package:health_anki_flutter/features/review/presentation/screens/primer_library_screen.dart';
import 'package:health_anki_flutter/theme/ui_tokens.dart';

void main() {
  testWidgets('standalone library mounts only viewport rows from 500 primers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pages = List.generate(500, (index) {
      final id = 499 - index;
      return ConceptPage(
        nodeId: 'synthetic-$id',
        title: 'Synthetic primer ${id.toString().padLeft(3, '0')}',
        bodyHtml: '',
        updatedAt: DateTime.utc(2026, 10, 15),
      );
    });
    final nodes = [
      for (final page in pages)
        ConceptNodeInfo(
          nodeId: page.nodeId,
          title: page.title,
          module:
              'Synthetic module ${int.parse(page.nodeId.split('-').last) ~/ 100}',
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRecallTheme(),
        home: PrimerLibraryScreen(pages: pages, conceptNodes: nodes),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PrimerRow).evaluate().length, inInclusiveRange(1, 39));
    expect(
      find.byKey(const ValueKey('recall_primer_row_synthetic-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recall_primer_row_synthetic-499')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
