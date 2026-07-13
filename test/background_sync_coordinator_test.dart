import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/core/background/background_sync_coordinator.dart';

class _FakeBackgroundSyncPlatform implements BackgroundSyncPlatform {
  Future<String> Function()? handler;
  var starts = 0;

  @override
  Future<void> start(Future<String> Function() onSyncRequested) async {
    starts++;
    handler = onSyncRequested;
  }
}

void main() {
  test('background sync reports new data when durable writes drain', () async {
    final platform = _FakeBackgroundSyncPlatform();
    final coordinator = BackgroundSyncCoordinator(
      platform: platform,
      sync: () async =>
          const BackgroundSyncReport(attempted: 3, delivered: 2, pending: 1),
    );

    await coordinator.start();

    expect(platform.starts, 1);
    expect(await platform.handler!(), 'newData');
  });

  test(
    'background sync reports no data when there was nothing queued',
    () async {
      final platform = _FakeBackgroundSyncPlatform();
      final coordinator = BackgroundSyncCoordinator(
        platform: platform,
        sync: () async =>
            const BackgroundSyncReport(attempted: 0, delivered: 0, pending: 0),
      );

      await coordinator.start();

      expect(await platform.handler!(), 'noData');
    },
  );

  test(
    'background sync reports failure without dropping pending writes',
    () async {
      final platform = _FakeBackgroundSyncPlatform();
      final coordinator = BackgroundSyncCoordinator(
        platform: platform,
        sync: () async =>
            const BackgroundSyncReport(attempted: 2, delivered: 0, pending: 2),
      );

      await coordinator.start();

      expect(await platform.handler!(), 'failed');
    },
  );
}
