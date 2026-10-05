import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'browser_sync_platform.dart';

BrowserSyncPlatform createPlatform() => _WebBrowserSyncPlatform();

class _WebBrowserSyncPlatform implements BrowserSyncPlatform {
  JSFunction? _listener;

  @override
  bool get supported => true;
  @override
  bool get visible => web.document.visibilityState == 'visible';
  @override
  bool get online => web.window.navigator.onLine;

  @override
  void start(void Function() onWake) {
    if (_listener != null) return;
    final listener = ((web.Event _) => onWake()).toJS;
    _listener = listener;
    web.window.addEventListener('online', listener);
    web.window.addEventListener('focus', listener);
    web.window.addEventListener('pageshow', listener);
    web.document.addEventListener('visibilitychange', listener);
  }

  @override
  void dispose() {
    final listener = _listener;
    if (listener == null) return;
    web.window.removeEventListener('online', listener);
    web.window.removeEventListener('focus', listener);
    web.window.removeEventListener('pageshow', listener);
    web.document.removeEventListener('visibilitychange', listener);
    _listener = null;
  }
}
