import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' show Rating;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;
import 'package:health_anki_flutter/features/review/application/fsrs_engine.dart';
import 'package:health_anki_flutter/features/review/application/review_controller.dart';
import 'package:health_anki_flutter/features/review/application/review_haptics.dart';
import 'package:health_anki_flutter/features/review/data/local_review_preferences.dart';
import 'package:health_anki_flutter/features/review/data/local_review_store.dart';

import '../tool/sync_lab_dart/file_preferences.dart';
import 'support/recall_test_harness.dart';

final _day = DateTime.utc(2026, 10, 16, 9);
const _owner = 'invented-keyed-read-owner';

/// One native read: what it shipped and what an unfiltered `getAll()` would
/// have shipped at the same moment (the pre-change cost of that read).
typedef _Read = ({
  bool keyed,
  Set<String> keys,
  int bytes,
  int fullKeys,
  int fullBytes,
});

int _bytes(Map<String, Object> values) =>
    utf8.encode(jsonEncode(values)).length;

GetAllParameters _allFlutter() =>
    GetAllParameters(filter: PreferencesFilter(prefix: 'flutter.'));

/// Counts keys and bytes returned by every native read.
class _CountingNative extends InMemorySharedPreferencesStore {
  _CountingNative() : super.empty();

  final reads = <_Read>[];
  bool failReads = false;

  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(_allFlutter());

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    if (failReads) throw StateError('Invented native read failure');
    final result = await super.getAllWithParameters(parameters);
    final full = await super.getAllWithParameters(_allFlutter());
    reads.add((
      keyed: parameters.filter.allowList != null,
      keys: result.keys.toSet(),
      bytes: _bytes(result),
      fullKeys: full.length,
      fullBytes: _bytes(full),
    ));
    return result;
  }
}

Future<_CountingNative> _install() async {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _CountingNative();
  SharedPreferencesStorePlatform.instance = native;
  addTearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  return native;
}

// Synthetic card HTML, sized like a real formatted card so the snapshot the
// old full read shipped is representative.
String _html(String side, int id) =>
    '<div class="card"><p>Invented $side $id</p>'
    '${'<span class="filler">synthetic padding</span>' * 40}</div>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an online rating reads only its own keys from native storage', () async {
    final native = await _install();
    final api = FakeRecallApi([
      for (var id = 1; id <= 20; id++)
        testCard(
          id: id,
          state: 2,
          stability: 4,
          difficulty: 5,
          due: _day.subtract(const Duration(days: 1)),
          lastReview: _day.subtract(const Duration(days: 5)),
          reps: 3,
          cloudSeen: true,
          front: _html('front', id),
          back: _html('back', id),
        ),
    ])..user = User(
        id: _owner,
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: _day.toIso8601String(),
      );
    final store = LocalReviewStore();
    final controller = ReviewController(
      api: api,
      engine: FsrsEngine(),
      store: store,
      clock: () => _day,
      haptics: const ReviewHaptics(),
    );
    addTearDown(controller.dispose);
    await store.activateOwner(_owner);
    await controller.load(keepReviewed: false);
    await pumpEventQueue();
    expect(controller.state.offline, isFalse);
    expect(controller.state.current?.id, 1);

    native.reads.clear();
    controller.flip();
    await controller.rate(Rating.good);
    await pumpEventQueue();
    final reads = List<_Read>.of(native.reads);

    // The rating was delivered and drained, so the measured reads are the
    // whole online path.
    expect(api.applied.map((entry) => entry['card_id']), [1]);
    expect(await store.outbox(), isEmpty);

    final scope = store.activeOwnerScope!;
    final snapshotKeys = (await native.getAll()).keys.where(
      (key) => key.startsWith('flutter.recall_snapshot_v1'),
    );
    expect(snapshotKeys, isNotEmpty);

    final before = (
      keys: reads.fold<int>(0, (sum, read) => sum + read.fullKeys),
      bytes: reads.fold<int>(0, (sum, read) => sum + read.fullBytes),
    );
    final after = (
      keys: reads.fold<int>(0, (sum, read) => sum + read.keys.length),
      bytes: reads.fold<int>(0, (sum, read) => sum + read.bytes),
    );
    // ignore: avoid_print
    print(
      jsonEncode({
        'metric': 'native_preference_reads_per_online_rating',
        'reads': reads.length,
        'before': {'keys': before.keys, 'bytes': before.bytes},
        'after': {'keys': after.keys, 'bytes': after.bytes},
      }),
    );

    expect(reads, isNotEmpty);
    for (final read in reads) {
      expect(read.keyed, isTrue, reason: 'every hot-path read is keyed');
      expect(read.keys.length, lessThanOrEqualTo(1));
      for (final key in read.keys) {
        expect(key, endsWith(':owner:$scope'));
        expect(snapshotKeys, isNot(contains(key)));
      }
    }
    // The old path shipped every snapshot, with its card HTML, on every read.
    expect(before.bytes, greaterThan(reads.length * 20000));
    expect(after.bytes * 50, lessThan(before.bytes));
    expect(after.keys, lessThan(before.keys));
  });

  group('keyed preference view', () {
    test('reads exactly the requested keys', () async {
      final native = await _install();
      await native.setValue('String', 'flutter.wanted', 'yes');
      await native.setValue('String', 'flutter.other', 'large');
      final writer = await SharedPreferences.getInstance();
      native.reads.clear();

      final view = await LocalReviewPreferences.readSnapshot(
        writer,
        keys: ['wanted', 'absent'],
      );

      expect(native.reads.single.keyed, isTrue);
      expect(native.reads.single.keys, {'flutter.wanted'});
      expect(view.getString('wanted'), 'yes');
      expect(view.getString('absent'), isNull);
      expect(() => view.getString('other'), throwsStateError);
      expect(view.getKeys, throwsStateError);
    });

    test('an empty key set reads nothing but still reads natively', () async {
      final native = await _install();
      await native.setValue('String', 'flutter.other', 'large');
      final writer = await SharedPreferences.getInstance();
      native.reads.clear();

      await LocalReviewPreferences.readSnapshot(writer, keys: const []);

      expect(native.reads.single.keyed, isTrue);
      expect(native.reads.single.keys, isEmpty);
    });

    test('acknowledged writes become readable', () async {
      await _install();
      final writer = await SharedPreferences.getInstance();
      final view = await LocalReviewPreferences.readSnapshot(
        writer,
        keys: const [],
      );

      expect(await view.setString('written', 'value'), isTrue);
      expect(await view.setBool('flag', true), isTrue);
      expect(await view.remove('removed'), isTrue);

      expect(view.getString('written'), 'value');
      expect(view.getBool('flag'), isTrue);
      expect(view.getString('removed'), isNull);
    });

    test('an unkeyed read still returns every key', () async {
      final native = await _install();
      await native.setValue('String', 'flutter.one', '1');
      await native.setValue('String', 'flutter.two', '2');
      final writer = await SharedPreferences.getInstance();
      native.reads.clear();

      final view = await LocalReviewPreferences.readSnapshot(writer);

      expect(native.reads.single.keyed, isFalse);
      expect(view.getKeys(), {'one', 'two'});
    });

    test('a failed keyed native read surfaces unchanged', () async {
      final native = await _install();
      final store = LocalReviewStore();
      await store.enqueueReview({'client_id': 'invented-1', 'card_id': 1});
      native.failReads = true;

      final failure = isA<StateError>().having(
        (error) => error.message,
        'message',
        'Invented native read failure',
      );
      await expectLater(store.outbox(), throwsA(failure));
      await expectLater(
        store.enqueueReview({'client_id': 'invented-2', 'card_id': 2}),
        throwsA(failure),
      );
      await expectLater(
        store.saveSnapshot(decks: const [], queue: const []),
        throwsA(failure),
      );
      await expectLater(store.loadSnapshot(), throwsA(failure));

      native.failReads = false;
      expect(
        (await store.outbox()).map((entry) => entry['client_id']),
        ['invented-1'],
      );
    });
  });

  test('the sync lab file store filters keyed reads', () async {
    final directory = await Directory.systemTemp.createTemp('keyed-reads-');
    addTearDown(() => directory.delete(recursive: true));
    final lab = LabFilePreferences(directory)..deviceId = 'invented-device';
    await lab.setValue('String', 'flutter.wanted', 'yes');
    await lab.setValue('String', 'flutter.other', 'no');
    await lab.setValue('String', 'unprefixed', 'no');

    expect(
      await lab.getAllWithParameters(
        GetAllParameters(
          filter: PreferencesFilter(
            prefix: 'flutter.',
            allowList: {'flutter.wanted', 'unprefixed'},
          ),
        ),
      ),
      {'flutter.wanted': 'yes'},
    );
    expect(await lab.getAllWithParameters(_allFlutter()), {
      'flutter.wanted': 'yes',
      'flutter.other': 'no',
    });
  });
}
