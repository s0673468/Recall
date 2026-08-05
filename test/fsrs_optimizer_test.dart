import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show defaultParameters;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/data/models.dart';
import 'package:health_anki_flutter/features/review/data/recall_api.dart';
import 'package:health_anki_flutter/features/settings/presentation/screens/settings_screen.dart';

final _parameters = List<double>.from(defaultParameters);

Map<String, dynamic> _report({DateTime? fittedAt}) => {
  'parameters': _parameters,
  'desired_retention': 0.86,
  if (fittedAt != null) 'fitted_at': fittedAt.toIso8601String(),
};

class _SettingsStub {
  Map<String, dynamic>? value;
  bool mismatchNextRead = false;
  bool mismatchAfterWrite = false;
  Map<String, dynamic>? concurrentValueBeforeReadback;
  bool _hasWritten = false;
  final List<http.BaseRequest> requests = [];

  Future<http.Response> handle(http.BaseRequest request) async {
    requests.add(request);
    if (request.method == 'GET') {
      if (value == null) {
        return _response(request, '[]');
      }
      if (_hasWritten && concurrentValueBeforeReadback != null) {
        value = Map<String, dynamic>.from(concurrentValueBeforeReadback!);
        concurrentValueBeforeReadback = null;
      }
      if (mismatchNextRead) {
        mismatchNextRead = false;
        final mismatch = {...value!, 'desired_retention': 0.71};
        return _response(
          request,
          jsonEncode([
            {'settings_value': mismatch},
          ]),
        );
      }
      return _response(
        request,
        jsonEncode([
          {'settings_value': value},
        ]),
      );
    }
    if (request.method == 'POST') {
      final body =
          jsonDecode((request as http.Request).body) as Map<String, dynamic>;
      value = Map<String, dynamic>.from(body['settings_value'] as Map);
      _hasWritten = true;
      if (mismatchAfterWrite) {
        mismatchAfterWrite = false;
        mismatchNextRead = true;
      }
      return _response(request, '', status: 201);
    }
    if (request.method == 'PATCH') {
      final body =
          jsonDecode((request as http.Request).body) as Map<String, dynamic>;
      final expected = _expectedValue(request);
      if (expected != null && !_sameJson(value, expected)) {
        return _response(request, '[]');
      }
      value = Map<String, dynamic>.from(body['settings_value'] as Map);
      return _response(
        request,
        jsonEncode([
          {'settings_key': 'fsrs_params'},
        ]),
      );
    }
    if (request.method == 'DELETE') {
      final expected = _expectedValue(request);
      final matched = expected == null || _sameJson(value, expected);
      if (matched) value = null;
      return _response(
        request,
        jsonEncode(
          matched
              ? [
                  {'settings_key': 'fsrs_params'},
                ]
              : [],
        ),
      );
    }
    return _response(request, '{}', status: 405);
  }

  Object? _expectedValue(http.BaseRequest request) {
    final filter = request.url.queryParameters['settings_value'];
    if (filter == null || !filter.startsWith('eq.')) return null;
    return jsonDecode(filter.substring(3));
  }

  http.Response _response(
    http.BaseRequest request,
    String body, {
    int status = 200,
  }) => http.Response(
    body,
    status,
    request: request,
    headers: {'content-type': 'application/json'},
  );
}

RecallApi _apiFor(_SettingsStub stub) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'anon-key',
    httpClient: MockClient(stub.handle),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  return RecallApi(client);
}

void main() {
  group('FsrsOptimizerResult', () {
    test('accepts the exact DIR-1a contract and preserves fitted date', () {
      final result = FsrsOptimizerResult.tryParse(
        _report(fittedAt: DateTime.utc(2026, 8, 5)),
      );

      expect(result, isNotNull);
      expect(result!.parameters, _parameters);
      expect(result.desiredRetention, 0.86);
      expect(result.fittedAt, DateTime.utc(2026, 8, 5));
      expect(
        result.toJson().keys,
        containsAll(['parameters', 'desired_retention']),
      );
    });

    test('rejects a wrong vector before an apply can start', () {
      expect(
        FsrsOptimizerResult.tryParse({
          'parameters': _parameters.sublist(0, 20),
          'desired_retention': 0.86,
        }),
        isNull,
      );
    });
  });

  group('RecallApi.applyFsrsOptimizerResult', () {
    test('refuses without explicit approval and makes no request', () async {
      final stub = _SettingsStub();
      final api = _apiFor(stub);

      await expectLater(
        api.applyFsrsOptimizerResult(
          _report(),
          confirmation: RecallApi.fsrsApplyConfirmation,
        ),
        throwsA(isA<FsrsOptimizerApplyException>()),
      );

      expect(stub.requests, isEmpty);
    });

    test('writes accepted parameters and proves exact readback', () async {
      final stub = _SettingsStub()
        ..value = {
          'parameters': List<double>.filled(21, 1),
          'desired_retention': 0.90,
        };
      final api = _apiFor(stub);

      final applied = await api.applyFsrsOptimizerResult(
        _report(fittedAt: DateTime.utc(2026, 8, 1)),
        approved: true,
        confirmation: RecallApi.fsrsApplyConfirmation,
        appliedAt: DateTime.utc(2026, 8, 5, 12, 30),
      );

      expect(applied.optimizerStatus, FsrsConfigurationStatus.applied);
      expect(applied.parameters, _parameters);
      expect(applied.fittedAt, DateTime.utc(2026, 8, 1));
      expect(applied.appliedAt, DateTime.utc(2026, 8, 5, 12, 30));
      expect(stub.value?['optimizer_status'], 'applied');
      expect(stub.requests.map((request) => request.method), [
        'GET',
        'POST',
        'GET',
      ]);
    });

    test('readback mismatch restores the prior row and fails closed', () async {
      final before = <String, dynamic>{
        'parameters': List<double>.filled(21, 1),
        'desired_retention': 0.90,
      };
      final stub = _SettingsStub()
        ..value = before
        ..mismatchAfterWrite = true;
      final api = _apiFor(stub);

      await expectLater(
        api.applyFsrsOptimizerResult(
          _report(),
          approved: true,
          confirmation: RecallApi.fsrsApplyConfirmation,
        ),
        throwsA(
          predicate<FsrsOptimizerApplyException>(
            (error) => error.message.contains('readback mismatch'),
          ),
        ),
      );

      expect(stub.value, before);
      expect(stub.requests.map((request) => request.method), [
        'GET',
        'POST',
        'GET',
        'GET',
        'PATCH',
        'GET',
      ]);
    });

    test('readback mismatch removes a newly-created row', () async {
      final stub = _SettingsStub()..mismatchAfterWrite = true;
      final api = _apiFor(stub);

      await expectLater(
        api.applyFsrsOptimizerResult(
          _report(),
          approved: true,
          confirmation: RecallApi.fsrsApplyConfirmation,
        ),
        throwsA(isA<FsrsOptimizerApplyException>()),
      );

      expect(stub.value, isNull);
      expect(stub.requests.map((request) => request.method), [
        'GET',
        'POST',
        'GET',
        'GET',
        'DELETE',
        'GET',
      ]);
    });

    test('does not roll back over a newer concurrent settings row', () async {
      final before = <String, dynamic>{
        'parameters': List<double>.filled(21, 1),
        'desired_retention': 0.90,
      };
      final newer = <String, dynamic>{
        'parameters': List<double>.filled(21, 2),
        'desired_retention': 0.88,
        'optimizer_status': 'applied',
        'applied_at': '2026-08-05T12:31:00.000Z',
      };
      final stub = _SettingsStub()
        ..value = before
        ..concurrentValueBeforeReadback = newer;
      final api = _apiFor(stub);

      await expectLater(
        api.applyFsrsOptimizerResult(
          _report(),
          approved: true,
          confirmation: RecallApi.fsrsApplyConfirmation,
        ),
        throwsA(
          predicate<FsrsOptimizerApplyException>(
            (error) => error.message.contains('changed concurrently'),
          ),
        ),
      );

      expect(stub.value, newer);
      expect(stub.requests.map((request) => request.method), [
        'GET',
        'POST',
        'GET',
        'GET',
      ]);
    });
  });

  testWidgets('Settings line shows defaults, suggested, and applied states', (
    tester,
  ) async {
    final engine = FsrsEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FsrsOptimizerStatusLine(engine: engine)),
      ),
    );
    expect(
      find.text('Scheduler: package defaults (21 weights)'),
      findsOneWidget,
    );

    engine.configure(
      FsrsSettings(
        parameters: _parameters,
        optimizerStatus: FsrsConfigurationStatus.suggested,
        fittedAt: DateTime.utc(2026, 8, 1),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FsrsOptimizerStatusLine(engine: engine)),
      ),
    );
    expect(
      find.textContaining('Scheduler: suggested parameters not applied'),
      findsOneWidget,
    );
    expect(engine.parameters, defaultParameters);

    engine.configure(
      FsrsSettings(
        parameters: _parameters,
        optimizerStatus: FsrsConfigurationStatus.applied,
        fittedAt: DateTime.utc(2026, 8, 1),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FsrsOptimizerStatusLine(engine: engine)),
      ),
    );
    expect(
      find.textContaining('Scheduler: personal parameters'),
      findsOneWidget,
    );
    expect(engine.parameters, _parameters);
  });
}

bool _sameJson(Object? left, Object? right) {
  if (left is num && right is num) return left == right;
  if (left == null || right == null || left is String || left is bool) {
    return left == right;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (!_sameJson(left[i], right[i])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_sameJson(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}
