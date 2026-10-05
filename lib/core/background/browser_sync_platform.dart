import 'browser_sync_platform_stub.dart'
    if (dart.library.js_interop) 'browser_sync_platform_web.dart'
    as platform;

/// Browser signals only wake the existing review/prefs synchronization path.
/// They never own an outbox, session, or cloud subscription.
abstract interface class BrowserSyncPlatform {
  bool get supported;
  bool get visible;
  bool get online;

  void start(void Function() onWake);
  void dispose();
}

BrowserSyncPlatform createBrowserSyncPlatform() => platform.createPlatform();
