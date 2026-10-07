import 'dart:convert';
import 'dart:js_interop';
import 'protocol.dart';

@JS('globalThis.recallDartSchedule')
external set scheduleExport(JSFunction function);

void main() {
  scheduleExport = ((JSString input) => jsonEncode(
    scheduleRequest(Map<String, dynamic>.from(jsonDecode(input.toDart) as Map)),
  ).toJS).toJS;
}
