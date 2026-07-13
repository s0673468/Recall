import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/navigation/recall_deep_links.dart';

void main() {
  test('accepts only the explicit Recall study route', () {
    expect(
      recallDestinationFor(Uri.parse('recall://study')),
      RecallDestination.study,
    );
    expect(recallDestinationFor(Uri.parse('recall://decks')), isNull);
    expect(recallDestinationFor(Uri.parse('https://study')), isNull);
    expect(recallDestinationFor(Uri.parse('recall://study/extra')), isNull);
    expect(recallDestinationFor(Uri.parse('recall://study?deck=1')), isNull);
    expect(recallDestinationFor(Uri.parse('recall://user@study')), isNull);
    expect(recallDestinationFor(Uri.parse('recall://study:123')), isNull);
  });

  test('controller dispatches safe initial and resumed study links', () async {
    final source = _FakeLinkSource(Uri.parse('recall://study'));
    final destinations = <RecallDestination>[];
    final controller = RecallDeepLinkController(
      source: source,
      onDestination: destinations.add,
    );

    await controller.start();
    source.add(Uri.parse('recall://decks'));
    source.add(Uri.parse('recall://study'));
    await Future<void>.delayed(Duration.zero);
    controller.dispose();

    expect(destinations, [RecallDestination.study, RecallDestination.study]);
  });

  test(
    'initial-link plugin failure is reported without escaping start',
    () async {
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previous);
      final controller = RecallDeepLinkController(
        source: _ThrowingLinkSource(),
        onDestination: (_) {},
      );

      await expectLater(controller.start(), completes);
      controller.dispose();

      expect(reported, hasLength(1));
      expect(reported.single.exception, isA<StateError>());
    },
  );
}

class _FakeLinkSource implements RecallLinkSource {
  final Uri? initial;
  final _controller = StreamController<Uri>.broadcast();

  _FakeLinkSource(this.initial);

  void add(Uri uri) => _controller.add(uri);

  @override
  Future<Uri?> getInitialLink() async => initial;

  @override
  Stream<Uri> get links => _controller.stream;
}

class _ThrowingLinkSource implements RecallLinkSource {
  @override
  Future<Uri?> getInitialLink() =>
      Future.error(StateError('plugin unavailable'));

  @override
  Stream<Uri> get links => const Stream<Uri>.empty();
}
