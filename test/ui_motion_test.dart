import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_anki_flutter/core/widgets/recall_motion.dart';

void main() {
  testWidgets('motion swap animates both directions and settles cleanly', (
    tester,
  ) async {
    Widget app(String label) => MaterialApp(
      home: Scaffold(
        body: RecallMotionSwap(child: Text(label, key: ValueKey(label))),
      ),
    );

    await tester.pumpWidget(app('First'));
    await tester.pumpWidget(app('Second'));
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    final outgoingPointerGate = tester
        .widgetList<IgnorePointer>(
          find.ancestor(
            of: find.text('First'),
            matching: find.byType(IgnorePointer),
          ),
        )
        .first;
    expect(outgoingPointerGate.ignoring, isTrue);

    await tester.pumpAndSettle();
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('reduced motion swaps content immediately', (tester) async {
    Widget app(String label) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: RecallMotionSwap(child: Text(label, key: ValueKey(label))),
        ),
      ),
    );

    await tester.pumpWidget(app('First'));
    await tester.pumpWidget(app('Second'));
    await tester.pump();

    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('animated tabs retain state and gate inactive interaction', (
    tester,
  ) async {
    Widget app(int index) => MaterialApp(
      home: Scaffold(
        body: RecallAnimatedIndexedStack(
          index: index,
          children: const [
            _CounterPage(key: ValueKey('first_page'), label: 'First'),
            _CounterPage(key: ValueKey('second_page'), label: 'Second'),
          ],
        ),
      ),
    );

    await tester.pumpWidget(app(0));
    await tester.tap(find.text('First 0'));
    await tester.pump();
    expect(find.text('First 1'), findsOneWidget);

    await tester.pumpWidget(app(1));
    await tester.pumpAndSettle();

    expect(find.text('First 1'), findsOneWidget);
    expect(find.text('Second 0'), findsOneWidget);
    final firstPagePointerGate = tester
        .widgetList<IgnorePointer>(
          find.ancestor(
            of: find.byKey(const ValueKey('first_page')),
            matching: find.byType(IgnorePointer),
          ),
        )
        .firstWhere((gate) => gate.ignoring);
    final firstPageSemanticsGate = tester
        .widgetList<ExcludeSemantics>(
          find.ancestor(
            of: find.byKey(const ValueKey('first_page')),
            matching: find.byType(ExcludeSemantics),
          ),
        )
        .firstWhere((gate) => gate.excluding);
    expect(firstPagePointerGate.ignoring, isTrue);
    expect(firstPageSemanticsGate.excluding, isTrue);
    final firstPageOpacity = tester.renderObject<RenderAnimatedOpacity>(
      find.byKey(const ValueKey('recall_tab_opacity_0')),
    );
    expect(firstPageOpacity.opacity.value, 0);
  });
}

class _CounterPage extends StatefulWidget {
  final String label;

  const _CounterPage({super.key, required this.label});

  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> {
  int value = 0;

  @override
  Widget build(BuildContext context) => Center(
    child: FilledButton(
      onPressed: () => setState(() => value++),
      child: Text('${widget.label} $value'),
    ),
  );
}
