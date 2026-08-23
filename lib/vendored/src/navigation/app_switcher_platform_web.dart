// Web implementation of the app-switcher platform hooks.

import 'package:web/web.dart' as web;

/// The document base URI reflects Flutter's injected `<base href>` and anchors
/// any explicitly configured relative Track or Recall root.
String? documentBaseUri() => web.document.baseURI;

/// Same-tab navigation. `location.assign` keeps a standalone (installed) PWA
/// in place; `window.open`/target=_blank would bounce the user out to a
/// separate browser tab.
Future<void> assignLocation(String? url, {String? preferredNativeUrl}) async {
  if (url != null) web.window.location.assign(url);
}
