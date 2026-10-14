import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'synthetic_recall_flow.dart';

const _sourceCommit = String.fromEnvironment('RECALL_BENCH_SOURCE_COMMIT');
const _fixtureBuild = bool.fromEnvironment('RECALL_SYNTHETIC_BENCHMARK');
const _schema = 'recall-synthetic-android/v1';
const _sentinel = 'RECALL_ANDROID_BENCH_JSON ';
const _limit = Duration(seconds: 35);

void _record(String phase, Map<String, Object?> values) {
  // Only closed numeric measurements, booleans and fixed schema labels. No
  // card text, auth identity, transport payload or exception text is logged.
  // ignore: avoid_print
  print(
    '$_sentinel${jsonEncode(<String, Object?>{'schema': _schema, 'phase': phase, 'source_commit': _sourceCommit, 'build_mode': 'debug', 'environment': 'isolated-android-emulator', 'pid': pid, ...values})}',
  );
}

Future<void> main() async {
  final entry = Stopwatch()..start();
  if (!_fixtureBuild ||
      !Platform.isAndroid ||
      !kDebugMode ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(_sourceCommit)) {
    _record('failed', const {'failure_code': 'fixture_build_required'});
    return;
  }
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final ready = ValueNotifier<bool>(false);
  runApp(_SyntheticBenchmarkRoot(ready: ready));
  SyntheticRecallFlow? flow;
  var phase = 'first_frame';
  try {
    await binding.waitUntilFirstFrameRasterized.timeout(_limit);
    final firstFrameUs = entry.elapsedMicroseconds;
    _record('first_frame', {'dart_main_elapsed_us': firstFrameUs});

    phase = 'fixture_setup';
    final setup = Stopwatch()..start();
    flow = await SyntheticRecallFlow.create(
      cardCount: 20,
      seededOutbox: 0,
      warmCache: false,
    ).timeout(_limit);
    setup.stop();

    phase = 'deck_load';
    final load = Stopwatch()..start();
    await flow.load().timeout(_limit);
    await flow.selectDeck(1).timeout(_limit);
    load.stop();
    if (flow.controller.state.loading ||
        flow.controller.state.queue.length != 20 ||
        flow.controller.state.current?.id != 1) {
      throw StateError('Synthetic readiness contract');
    }
    ready.value = true;
    await binding.endOfFrame.timeout(_limit);
    final rootReadyUs = entry.elapsedMicroseconds;
    _record('root_ready', {'dart_main_elapsed_us': rootReadyUs});

    phase = 'rating';
    final rate = Stopwatch()..start();
    await flow.rateFirstGood().timeout(_limit);
    rate.stop();
    final pending = await flow.store.outbox().timeout(_limit);
    if (flow.controller.state.current?.id != 2 ||
        flow.controller.state.reviewedThisSession != 1 ||
        pending.length != 1 ||
        pending.single['card_id'] != 1) {
      throw StateError('Synthetic native acknowledgement contract');
    }
    final nativeAckUs = flow.store.lastEnqueueAckUs;
    final requests = flow.httpFixture.totalRequests;
    phase = 'dispose';
    await flow.close().timeout(_limit);
    flow = null;
    _record('done', {
      'timing_us': {
        'dart_main_first_frame': firstFrameUs,
        'dart_main_root_ready': rootReadyUs,
        'fixture_setup': setup.elapsedMicroseconds,
        'deck_load': load.elapsedMicroseconds,
        'rating_to_next': rate.elapsedMicroseconds,
        'native_enqueue_ack': nativeAckUs,
      },
      'integrity': {
        'cards_loaded': 20,
        'pending_after_rating': pending.length,
        'next_card_id': 2,
        'http_requests': requests,
        'native_preferences': true,
      },
    });
  } catch (_) {
    _record('failed', {
      'failure_code': 'synthetic_phase_failed',
      'failed_phase': phase,
    });
  } finally {
    if (flow != null) {
      try {
        await flow.close().timeout(const Duration(seconds: 5));
      } catch (_) {
        // The consumer observes only the preceding closed failure record.
      }
    }
  }
}

class _SyntheticBenchmarkRoot extends StatelessWidget {
  const _SyntheticBenchmarkRoot({required this.ready});

  final ValueListenable<bool> ready;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: Center(
        child: ValueListenableBuilder<bool>(
          valueListenable: ready,
          builder: (context, loaded, child) => Text(
            loaded
                ? 'Synthetic benchmark ready'
                : 'Synthetic benchmark starting',
          ),
        ),
      ),
    ),
  );
}
