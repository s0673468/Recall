import 'package:web/web.dart' as web;

void dispatchBrowserSyncEvents() {
  web.window.dispatchEvent(web.Event('online'));
  web.window.dispatchEvent(web.Event('focus'));
  web.window.dispatchEvent(web.Event('pageshow'));
  web.document.dispatchEvent(web.Event('visibilitychange'));
}
