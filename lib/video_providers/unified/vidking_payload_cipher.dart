import 'dart:convert';

/// Decodes Vidking's application-level source payload using the public
/// client-side algorithm reproduced from OpenStream's MIT-licensed adapter.
/// This only decrypts the API response envelope; it does not handle DRM keys
/// or bypass playback licensing.
abstract final class VidkingPayloadCipher {
  static const int _mask = 0xFFFFFFFF;
  static const List<int> _keySchedule = <int>[
    1116352408,
    1899447441,
    3049323471,
    3921009573,
    961987163,
    1508970993,
    2453635748,
    2870763221,
    3624381080,
    310598401,
    607225278,
    1426881987,
    1925078388,
    2162078206,
    2614888103,
    3248222580,
  ];
  static const List<int> _initialHash = <int>[
    1732584193,
    4023233417,
    2562383102,
    271733878,
  ];
  static const List<int> _magic = <int>[109, 118, 109, 49]; // mvm1
  static const int _sparseSize = 61;
  static const int _rounds = 8;
  static const int _golden = 2654435769;

  static String decrypt(String encoded, String seed, int mediaId) {
    if (seed.isEmpty) throw const FormatException('Vidking seed is empty.');
    final normalized = encoded.trim().replaceAll('-', '+').replaceAll('_', '/');
    final encrypted = base64.decode(base64.normalize(normalized));
    if (encrypted.length < _magic.length) {
      throw const FormatException('Vidking payload is too short.');
    }
    final stream = _keyStream(seed, mediaId, encrypted.length);
    final decrypted = List<int>.generate(
      encrypted.length,
      (index) => encrypted[index] ^ stream[index],
      growable: false,
    );
    for (var index = 0; index < _magic.length; index++) {
      if (decrypted[index] != _magic[index]) {
        throw const FormatException(
          'Vidking payload failed integrity validation.',
        );
      }
    }
    return utf8.decode(decrypted.skip(_magic.length).toList());
  }

  static List<int> _keyStream(String seed, int mediaId, int size) {
    final state = _createState(seed, mediaId);
    final bytes = List<int>.filled(size, 0);
    var outputIndex = 0;
    var blockIndex = 0;
    while (outputIndex < size) {
      final value = _next(state, blockIndex++);
      for (var byteIndex = 0; byteIndex < 4 && outputIndex < size; byteIndex++) {
        bytes[outputIndex++] = (value >> (byteIndex * 8)) & 0xFF;
      }
    }
    return bytes;
  }

  static _CipherState _createState(String seed, int mediaId) {
    if (_hasOddTriangularParity(seed.length)) {
      final values = List<int?>.generate(256, (index) => index);
      var cursor = 0;
      final codeUnits = seed.codeUnits;
      for (var index = 0; index < values.length; index++) {
        cursor = (cursor + values[index]! + codeUnits[index % codeUnits.length]) & 255;
        final previous = values[index];
        values[index] = values[cursor];
        values[cursor] = previous;
      }
      return _CipherState(values, _hashSeed(seed));
    }

    final values = List<int?>.filled(_sparseSize, null);
    var accumulator = _mix(_fnv(seed) ^ _mix((mediaId & _mask) ^ _golden));
    for (var round = 0; round < _rounds; round++) {
      if (_hasEvenTriangularParity(round)) {
        final index = accumulator % _sparseSize;
        accumulator = _rotateLeft(
          (accumulator + _golden) & _mask,
          7 + (round & 7),
        );
        values[index] = accumulator ^ _mix(accumulator);
        accumulator = _mix((accumulator + index) & _mask);
      } else {
        values[round] = _keySchedule[round & 15];
      }
    }
    return _CipherState(values, _mix(accumulator ^ 0xA5A5A5A5));
  }

  static int _next(_CipherState state, int outputIndex) {
    final accumulator = state.accumulator;
    final stateIndex = accumulator % _sparseSize;
    final stored = state.values[stateIndex];
    final derived = ((stored ?? 0) ^ ((_golden * (outputIndex + 1)) & _mask)) & _mask;
    final combined = stored != null
        ? (accumulator | derived) & _mask
        : (accumulator ^ derived) & _mask;
    final rotated = _rotateLeft(
          (combined + accumulator) & _mask,
          stateIndex & 31,
        ) ^
        _rotateLeft(accumulator, (stateIndex * 7) & 31);
    final nextAccumulator = _mix((rotated + _golden) & _mask);
    state.values[stateIndex] = nextAccumulator;
    state.accumulator = nextAccumulator;
    return nextAccumulator;
  }

  static int _mix(int input) {
    var value = input & _mask;
    value = (value ^ (value >> 16)) & _mask;
    value = (value * 2246822507) & _mask;
    value = (value ^ (value >> 13)) & _mask;
    value = (value * 3266489909) & _mask;
    value = (value ^ (value >> 16)) & _mask;
    return value;
  }

  static int _hashSeed(String seed) {
    var value = _initialHash[0];
    final codeUnits = seed.codeUnits;
    for (var index = 0; index < codeUnits.length; index++) {
      value = _rotateLeft(
        value ^ ((codeUnits[index] * _keySchedule[index & 15]) & _mask),
        5,
      );
    }
    return _mix(value);
  }

  static int _fnv(String seed) {
    var value = 2166136261;
    for (final codeUnit in seed.codeUnits) {
      value = ((value ^ codeUnit) * 16777619) & _mask;
    }
    return _mix(value);
  }

  static int _rotateLeft(int value, int bits) {
    final shift = bits & 31;
    final normalized = value & _mask;
    if (shift == 0) return normalized;
    return ((normalized << shift) | (normalized >> (32 - shift))) & _mask;
  }

  static bool _hasEvenTriangularParity(int value) =>
      ((value * (value + 1)) & 1) == 0;

  static bool _hasOddTriangularParity(int value) =>
      ((value * (value + 1)) & 1) == 1;
}

class _CipherState {
  _CipherState(this.values, this.accumulator);

  final List<int?> values;
  int accumulator;
}
