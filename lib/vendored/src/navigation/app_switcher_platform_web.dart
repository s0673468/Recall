// Web implementation of the app-switcher platform hooks.

import 'package:web/web.dart' as web;

/// The document base URI (reflects the `<base href>` Flutter injects per
/// deployed subpath), used to resolve the suite root at runtime so the
/// switcher works on any host — not just the GitHub Pages origin.
String? documentBaseUri() => web.document.baseURI;

/// Same-tab navigation. `location.assign` keeps a standalone (installed) PWA
/// in place; `window.open`/target=_blank would bounce the user out to a
/// separate browser tab.
Future<void> assignLocation(String url) async =>
    web.window.location.assign(url);
