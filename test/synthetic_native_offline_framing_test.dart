import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/fixtures/synthetic_native_offline_restart_main.dart';

void main() {
  test('compact Unicode golden agrees with the strict Python decoder', () {
    expect(syntheticNativeReceiptFrames({'fixture': 'é😀', 'n': 1}), [
      'RECALL_NATIVE_OFFLINE_CHUNK v1 '
          'cc68394a6ea3c7be965917ecb8a742d31a58456604fc2cb20b02082a8091fafe '
          '26 0 1 eyJmaXh0dXJlIjoiw6nwn5iAIiwibiI6MX0=',
    ]);
  });

  test(
    'large Unicode receipt uses bounded ASCII packets and lossless bytes',
    () {
      final receipt = <String, dynamic>{
        'schema': 'invented-framing-fixture',
        'generated': List.filled(200, 'é😀').join(),
      };
      final expected = utf8.encode(jsonEncode(receipt));
      expect(expected.length, greaterThan(1023));
      final lines = syntheticNativeReceiptFrames(receipt);
      expect(lines.length, (expected.length + 239) ~/ 240);
      final assembled = <int>[];
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        expect(line.codeUnits.every((unit) => unit < 128), isTrue);
        expect(utf8.encode(line).length, lessThanOrEqualTo(512));
        final fields = line.split(' ');
        expect(fields.length, 7);
        expect(fields[0], 'RECALL_NATIVE_OFFLINE_CHUNK');
        expect(fields[1], 'v1');
        expect(fields[2], sha256.convert(expected).toString());
        expect(int.parse(fields[3]), expected.length);
        expect(int.parse(fields[4]), index);
        expect(int.parse(fields[5]), lines.length);
        final bytes = base64Url.decode(fields[6]);
        expect(base64Url.encode(bytes), fields[6]);
        expect(
          bytes.length,
          index + 1 < lines.length ? 240 : expected.length - index * 240,
        );
        assembled.addAll(bytes);
      }
      expect(assembled, expected);
      expect(jsonDecode(utf8.decode(assembled)), receipt);
    },
  );

  test(
    'size boundary includes metadata bytes and refuses oversize receipts',
    () {
      // The compact {"x":""} envelope contributes eight bytes.
      final atLimit = {'x': List.filled(8184, 'x').join()};
      expect(utf8.encode(jsonEncode(atLimit)).length, 8192);
      expect(syntheticNativeReceiptFrames(atLimit).length, 35);
      final overLimit = {'x': List.filled(8185, 'x').join()};
      expect(() => syntheticNativeReceiptFrames(overLimit), throwsStateError);
    },
  );
}
