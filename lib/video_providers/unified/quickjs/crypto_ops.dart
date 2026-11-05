import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

String sha256Hex(String message) =>
    crypto.sha256.convert(utf8.encode(message)).toString();

Uint8List _hexToBytes(String hex) {
  final normalized = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (normalized.length.isOdd) {
    throw const FormatException('Hex input must contain complete bytes.');
  }
  return Uint8List.fromList(List<int>.generate(
    normalized.length ~/ 2,
    (index) => int.parse(
      normalized.substring(index * 2, index * 2 + 2),
      radix: 16,
    ),
  ));
}

/// AES-256-CTR helper used by Zangetsu-compatible provider scripts.
String aesCtrDecryptToString({
  required String keyHex,
  required String counterHex,
  required Uint8List data,
}) {
  final key = _hexToBytes(keyHex);
  final counter = _hexToBytes(counterHex);
  if (key.length != 32 || counter.length != 16) {
    throw const FormatException('AES-256-CTR requires a 32-byte key and 16-byte counter.');
  }
  final cipher = CTRStreamCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(key), counter));
  return utf8.decode(cipher.process(data), allowMalformed: true);
}

/// AES-CBC/PKCS7 decrypt used by OpenStream's MegaPlay resolver.
String aesCbcDecryptUtf8({
  required Uint8List key,
  required Uint8List iv,
  required Uint8List data,
}) {
  if (key.length != 32 || iv.length != 16 || data.isEmpty || data.length % 16 != 0) {
    throw const FormatException('Invalid AES-CBC key, IV, or ciphertext length.');
  }
  final cipher = PaddedBlockCipher('AES/CBC/PKCS7')
    ..init(
      false,
      PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
        ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
        null,
      ),
    );
  return utf8.decode(cipher.process(data), allowMalformed: true);
}
