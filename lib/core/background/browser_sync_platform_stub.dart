import 'browser_sync_platform.dart';

BrowserSyncPlatform createPlatform() => _UnsupportedBrowserSyncPlatform();

class _UnsupportedBrowserSyncPlatform implements BrowserSyncPlatform {
  @override
  bool get supported => false;
  @override
  bool get visible => false;
  @override
  bool get online => false;
  @override
  void start(void Function() onWake) {}
  @override
  void dispose() {}
}
