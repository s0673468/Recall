import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef BackgroundSyncAction = Future<BackgroundSyncReport> Function();

class BackgroundSyncReport {
  final int attempted;
  final int delivered;
  final int pending;

  const BackgroundSyncReport({
    required this.attempted,
    required this.delivered,
    required this.pending,
  });

  String get nativeResult {
    if (delivered > 0) return 'newData';
    if (attempted > 0 && pending > 0) return 'failed';
    return 'noData';
  }
}

abstract class BackgroundSyncPlatform {
  Future<void> start(Future<String> Function() onSyncRequested);
}

class MethodChannelBackgroundSyncPlatform implements BackgroundSyncPlatform {
  static const _channel = MethodChannel('com.german.ankiReview/backgroundSync');

  const MethodChannelBackgroundSyncPlatform();

  @override
  Future<void> start(Future<String> Function() onSyncRequested) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'performSync') return 'failed';
      return onSyncRequested();
    });
    await _channel.invokeMethod<void>('ready');
  }
}

class BackgroundSyncCoordinator {
  final BackgroundSyncPlatform platform;
  final BackgroundSyncAction sync;

  const BackgroundSyncCoordinator({required this.platform, required this.sync});

  Future<void> start() => platform.start(_performSync);

  Future<String> _performSync() async {
    try {
      return (await sync()).nativeResult;
    } catch (error, stack) {
      debugPrint('Recall background sync failed: $error\n$stack');
      return 'failed';
    }
  }
}
