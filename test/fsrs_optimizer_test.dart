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
  final List<http.BaseRequest> requests = [];

  Future<http.Response> handle(http.BaseRequest request) async {
    requests.add(request);
    if (request.method == 'GET') {
      if (value == null) {
        return _response(request, '[]');
      }
      if (mismatchNextRead) {
        value = {...value!, 'desired_retention': 0.71};
        mismatchNextRead = false;
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
      if (mismatchAfterWrite) {
        mismatchAfterWrite = false;
        mismatchNextRead = true;
      }
      return _response(request, '', status: 201);
    }
    if (request.method == 'DELETE') {
      value = null;
      return _response(request, '', status: 204);
    }
    return _response(request, '{}', status: 405);
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
        'POST',
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
        'DELETE',
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
