import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/core/diagnostics/operational_diagnostics_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const exporter = MethodChannelOperationalEventExporter();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          MethodChannelOperationalEventExporter.channel,
          (call) async {
            calls.add(call);
            return null;
          },
        );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          MethodChannelOperationalEventExporter.channel,
          null,
        );
  });

  test(
    'iOS sends only the canonical encoded array to the native mirror',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final encoded = jsonEncode([_event()]);

      await exporter.export(encoded);

      expect(calls, [
        const TypeMatcher<MethodCall>()
            .having((call) => call.method, 'method', 'mirror')
            .having((call) => call.arguments, 'arguments', {
              'payload': encoded,
            }),
      ]);
    },
  );

  test(
    'Android sends only the canonical encoded array to the native mirror',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final encoded = jsonEncode([_event()]);

      await exporter.export(encoded);

      expect(calls, [
        const TypeMatcher<MethodCall>()
            .having((call) => call.method, 'method', 'mirror')
            .having((call) => call.arguments, 'arguments', {
              'payload': encoded,
            }),
      ]);
    },
  );

  test('non-mobile native platforms are a no-op', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    await exporter.export(jsonEncode([_event()]));

    expect(calls, isEmpty);
  });

  test('malformed payloads never reach Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final withCardKey = _event()..['card_id'] = 42;

    await exporter.export('{bad json');
    await exporter.export(jsonEncode([withCardKey]));

    expect(calls, isEmpty);
  });

  test(
    'malformed, non-canonical, and oversized payloads never reach iOS',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final withCardKey = _event()..['card_id'] = 42;

      await exporter.export('{bad json');
      await exporter.export(jsonEncode([withCardKey]));
      await exporter.export(jsonEncode(List.filled(101, _event())));
      await exporter.export('["${'x' * (64 * 1024)}"]');

      expect(calls, isEmpty);
    },
  );
}

Map<String, Object?> _event() => {
  'schema': 'operational-event/v2',
  'timestamp': '2026-07-28T15:00:00.000Z',
  'level': 'error',
  'project': 'recall',
  'component': 'auth',
  'operation': 'observe_auth_state',
  'outcome': 'failed',
  'cause_code': 'auth.stream_error',
  'retryable': true,
  'run_id': 'run-test',
};
