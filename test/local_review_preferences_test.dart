import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:health_anki_flutter/features/review/data/local_review_preferences.dart';

enum _Operation { string, boolean, removal }

enum _Failure { refused, thrown }

class _SyntheticNative extends InMemorySharedPreferencesStore {
  _SyntheticNative(super.data) : super.withData();

  String? failedKey;
  _Failure failure = _Failure.refused;
  final nativeError = StateError('invented native failure');

  bool? _failureFor(String key) {
    if (key != failedKey) return null;
    if (failure == _Failure.thrown) throw nativeError;
    return false;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      _failureFor(key) ?? await super.setValue(valueType, key, value);

  @override
  Future<bool> remove(String key) async =>
      _failureFor(key) ?? await super.remove(key);
}

Future<(SharedPreferences, _SyntheticNative)> _install(
  Map<String, Object> initial,
) async {
  final previous = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  final native = _SyntheticNative(initial);
  SharedPreferencesStorePlatform.instance = native;
  addTearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });
  return (await SharedPreferences.getInstance(), native);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'new native snapshot sees later data and preserves global pending cache',
    () async {
      final (writer, native) = await _install({
        'flutter.early': 'invented early value',
        'outside.prefix': 'ignored',
      });
      const pending = 'invented_pending_settings';
      native.failedKey = 'flutter.$pending';
      expect(await writer.setString(pending, 'pending edit'), isFalse);
      expect(writer.getString(pending), 'pending edit');
      expect((await native.getAll()).containsKey('flutter.$pending'), isFalse);

      await native.setValue('String', 'flutter.late', 'invented late value');
      expect(writer.getString('late'), isNull);
      final snapshot = await LocalReviewPreferences.readSnapshot(writer);

      expect(snapshot.getString('early'), 'invented early value');
      expect(snapshot.getString('late'), 'invented late value');
      expect(snapshot.getString(pending), isNull);
      expect(snapshot.getKeys(), {'early', 'late'});
      expect(writer.getString(pending), 'pending edit');
      expect(writer.getString('late'), isNull);
    },
  );

  test(
    'acknowledged string, bool, and removal update only the owned view',
    () async {
      final (writer, native) = await _install({
        'flutter.invented_remove': 'old value',
      });
      final snapshot = await LocalReviewPreferences.readSnapshot(writer);

      expect(await snapshot.setString('invented_string', 'new value'), isTrue);
      expect(await snapshot.setBool('invented_bool', true), isTrue);
      expect(await snapshot.remove('invented_remove'), isTrue);

      expect(snapshot.getString('invented_string'), 'new value');
      expect(snapshot.getBool('invented_bool'), isTrue);
      expect(snapshot.getString('invented_remove'), isNull);
      expect(snapshot.getKeys(), {'invented_string', 'invented_bool'});
      snapshot.getKeys().clear();
      expect(snapshot.getKeys(), {'invented_string', 'invented_bool'});
      expect(await native.getAll(), {
        'flutter.invented_string': 'new value',
        'flutter.invented_bool': true,
      });
    },
  );

  for (final operation in _Operation.values) {
    for (final failure in _Failure.values) {
      test(
        '$failure $operation keeps native truth in old and fresh views',
        () async {
          const key = 'invented_target';
          final original = operation == _Operation.boolean
              ? true
              : 'invented original';
          final (writer, native) = await _install({'flutter.$key': original});
          final snapshot = await LocalReviewPreferences.readSnapshot(writer);
          native
            ..failedKey = 'flutter.$key'
            ..failure = failure;

          final Future<bool> action = switch (operation) {
            _Operation.string => snapshot.setString(
              key,
              'invented replacement',
            ),
            _Operation.boolean => snapshot.setBool(key, false),
            _Operation.removal => snapshot.remove(key),
          };
          if (failure == _Failure.refused) {
            expect(await action, isFalse);
          } else {
            await expectLater(action, throwsA(same(native.nativeError)));
          }

          expect((await native.getAll())['flutter.$key'], original);
          expect(snapshot.getKeys(), contains(key));
          final fresh = await LocalReviewPreferences.readSnapshot(writer);
          expect(fresh.getKeys(), contains(key));
          if (operation == _Operation.boolean) {
            expect(writer.getBool(key), isFalse); // Eager global cache ghost.
            expect(snapshot.getBool(key), isTrue);
            expect(fresh.getBool(key), isTrue);
          } else {
            expect(
              writer.getString(key),
              operation == _Operation.removal ? isNull : 'invented replacement',
            );
            expect(snapshot.getString(key), 'invented original');
            expect(fresh.getString(key), 'invented original');
          }
        },
      );
    }
  }
}
