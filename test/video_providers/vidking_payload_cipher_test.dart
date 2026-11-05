import 'package:flixquest/video_providers/unified/vidking_payload_cipher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VidkingPayloadCipher', () {
    test('rejects an empty seed before decoding', () {
      expect(
        () => VidkingPayloadCipher.decrypt('bXZtMQ==', '', 1),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects invalid encrypted payload integrity', () {
      expect(
        () => VidkingPayloadCipher.decrypt('AAAA', 'seed-value', 123),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects payloads shorter than the magic prefix', () {
      expect(
        () => VidkingPayloadCipher.decrypt('', 'seed-value', 123),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
