import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_anki_flutter/core/background/browser_sync_platform.dart';

import 'browser_sync_events_stub.dart'
    if (dart.library.js_interop) 'browser_sync_events_web.dart';

void main() {
  test(
    'browser reconnect and foreground DOM events wake once and detach on dispose',
    () {
      final platform = createBrowserSyncPlatform();
      expect(platform.supported, isTrue);
      var wakes = 0;
      platform.start(() => wakes++);
      platform.start(() => wakes += 100);
      dispatchBrowserSyncEvents();
      expect(wakes, 4);
      platform.dispose();
      dispatchBrowserSyncEvents();
      expect(wakes, 4);
    },
    skip: !kIsWeb,
  );
}
