import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Decodes the subtitle containers used by external subtitle catalogues and
/// returns WebVTT, the common format consumed by BetterPlayer.
///
/// OpenSubtitles commonly serves gzip-compressed SRT/VTT. SubSource serves ZIP
/// archives containing SRT/VTT (and occasionally ASS/SSA). The archive member
/// is selected by subtitle extension and size, never by an untrusted URL suffix.
class SubtitleFileNormalizer {
  SubtitleFileNormalizer._();

  static const int maxArchiveEntries = 256;
  static const int maxExpandedBytes = 24 * 1024 * 1024;
  static const List<String> supportedExtensions = <String>[
    '.srt',
    '.vtt',
    '.ass',
    '.ssa',
  ];

  static String normalizeBytes(List<int> input) {
    if (input.isEmpty) throw const FormatException('Subtitle file is empty.');
    if (input.length > maxExpandedBytes) {
      throw const FormatException('Subtitle download exceeds the size limit.');
    }
    var bytes = List<int>.of(input, growable: false);

    // ZIP is identified by its magic bytes, as SubSource may return an archive
    // even when the detail endpoint does not expose the final file extension.
    if (_isZip(bytes)) {
      bytes = _largestSubtitleFromZip(bytes);
    } else if (_isGzip(bytes)) {
      bytes = gzip.decode(bytes);
    }

    if (bytes.isEmpty || bytes.length > maxExpandedBytes) {
      throw const FormatException('Subtitle file is empty or too large.');
    }

    final text = _decodeText(bytes).replaceFirst('\uFEFF', '');
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('<!DOCTYPE html') ||
        trimmed.startsWith('<html') ||
        trimmed.startsWith('{"error"')) {
      throw const FormatException(
        'Subtitle provider returned an error page instead of a subtitle file.',
      );
    }

    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (normalized.trimLeft().startsWith('WEBVTT')) {
      return _normalizeWebVtt(normalized);
    }
    if (normalized.contains('[Events]') &&
        RegExp(r'^Dialogue:', multiLine: true, caseSensitive: false)
            .hasMatch(normalized)) {
      return _assToWebVtt(normalized);
    }
    if (RegExp(
      r'\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}',
    ).hasMatch(normalized)) {
      return _srtToWebVtt(normalized);
    }

    throw const FormatException('Unsupported or malformed subtitle format.');
  }

  static bool _isZip(List<int> bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4b &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04;

  static bool _isGzip(List<int> bytes) =>
      bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

  static List<int> _largestSubtitleFromZip(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(Uint8List.fromList(bytes), verify: true);
    if (archive.files.length > maxArchiveEntries) {
      throw const FormatException('Subtitle archive contains too many files.');
    }
    ArchiveFile? selected;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.toLowerCase();
      if (!supportedExtensions.any(name.endsWith)) continue;
      if (file.size > maxExpandedBytes) continue;
      if (selected == null || file.size > selected.size) selected = file;
    }
    if (selected == null) {
      throw const FormatException(
        'Subtitle archive does not contain an SRT, VTT, ASS, or SSA file.',
      );
    }
    // archive 4.x exposes file contents through readBytes(); `content` is a
    // FileContent handle, not the decompressed byte list used by archive 3.x.
    final content = selected.readBytes();
    if (content == null || content.isEmpty) {
      throw const FormatException('Subtitle archive member is unreadable.');
    }
    return List<int>.of(content, growable: false);
  }

  static String _decodeText(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      // Match OpenStream's Windows-1252 fallback. Latin-1 alone maps the
      // 0x80-0x9F range to control characters and corrupts common quotes,
      // dashes and currency symbols in older community subtitle files.
      return _decodeWindows1252(bytes);
    }
  }

  static String _decodeWindows1252(List<int> bytes) {
    const replacements = <int, int>{
      0x80: 0x20AC, 0x81: 0xFFFD, 0x82: 0x201A, 0x83: 0x0192,
      0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
      0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039,
      0x8C: 0x0152, 0x8D: 0xFFFD, 0x8E: 0x017D, 0x8F: 0xFFFD,
      0x90: 0xFFFD, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C,
      0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
      0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A,
      0x9C: 0x0153, 0x9D: 0xFFFD, 0x9E: 0x017E, 0x9F: 0x0178,
    };
    return String.fromCharCodes(
      bytes.map((byte) => replacements[byte] ?? byte),
    );
  }

  static String _normalizeWebVtt(String text) {
    final clean = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();
    if (!clean.startsWith('WEBVTT')) {
      throw const FormatException('Malformed WebVTT header.');
    }
    if (!RegExp(r'-->').hasMatch(clean)) {
      throw const FormatException('WebVTT file contains no subtitle cues.');
    }
    return '$clean\n';
  }

  static String _srtToWebVtt(String text) {
    final clean = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final timestamp = RegExp(
      r'(\d{1,2}:\d{2}:\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2})[,.](\d{1,3})',
    );
    final blocks = clean.split(RegExp(r'\n\s*\n'));
    final cues = <String>[];
    for (final block in blocks) {
      final lines = block.split('\n');
      final timingIndex = lines.indexWhere((line) => timestamp.hasMatch(line));
      if (timingIndex < 0) continue;
      final match = timestamp.firstMatch(lines[timingIndex]);
      if (match == null) continue;
      final start = '${match.group(1)}.${match.group(2)!.padRight(3, '0').substring(0, 3)}';
      final end = '${match.group(3)}.${match.group(4)!.padRight(3, '0').substring(0, 3)}';
      final body = lines.skip(timingIndex + 1).join('\n').trim();
      if (body.isEmpty) continue;
      cues.add('$start --> $end\n${_cleanCueText(body)}');
    }
    if (cues.isEmpty) throw const FormatException('SRT file contains no valid cues.');
    return 'WEBVTT\n\n${cues.join('\n\n')}\n';
  }

  static String _assToWebVtt(String text) {
    final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final eventsStart = lines.indexWhere(
      (line) => line.trim().equalsIgnoreCase('[Events]'),
    );
    if (eventsStart < 0) throw const FormatException('ASS subtitle has no Events section.');

    var fields = <String>[];
    for (var i = eventsStart + 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('[') && line.endsWith(']')) break;
      if (line.toLowerCase().startsWith('format:')) {
        fields = line.substring(line.indexOf(':') + 1)
            .split(',')
            .map((value) => value.trim().toLowerCase())
            .toList();
        break;
      }
    }
    final startIndex = fields.indexOf('start');
    final endIndex = fields.indexOf('end');
    final textIndex = fields.indexOf('text');
    if (startIndex < 0 || endIndex < 0 || textIndex < 0) {
      throw const FormatException('ASS subtitle has an unsupported Events format.');
    }

    final cues = <String>[];
    for (final raw in lines.skip(eventsStart + 1)) {
      if (!raw.trimLeft().toLowerCase().startsWith('dialogue:')) continue;
      final payload = raw.substring(raw.indexOf(':') + 1).trimLeft();
      final parts = payload.split(',');
      if (parts.length < fields.length) continue;
      // ASS Text is the final formatted field and may itself contain commas.
      final values = <String>[...parts.take(fields.length - 1), parts.skip(fields.length - 1).join(',')];
      final start = _assTimeToVtt(values[startIndex]);
      final end = _assTimeToVtt(values[endIndex]);
      final body = _cleanCueText(
        values[textIndex]
            .replaceAll(RegExp(r'\{[^}]*\}'), '')
            .replaceAll(r'\N', '\n')
            .replaceAll(r'\n', '\n')
            .replaceAll(r'\h', ' '),
      );
      if (body.isEmpty) continue;
      cues.add('$start --> $end\n$body');
    }
    if (cues.isEmpty) throw const FormatException('ASS subtitle contains no valid dialogue cues.');
    return 'WEBVTT\n\n${cues.join('\n\n')}\n';
  }

  static String _assTimeToVtt(String raw) {
    final match = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})[.](\d{1,2})$').firstMatch(raw.trim());
    if (match == null) throw const FormatException('Invalid ASS timestamp.');
    final hours = match.group(1)!.padLeft(2, '0');
    final minutes = match.group(2)!.padLeft(2, '0');
    final seconds = match.group(3)!.padLeft(2, '0');
    final milliseconds = match.group(4)!.padRight(3, '0').substring(0, 3);
    return '$hours:$minutes:$seconds.$milliseconds';
  }

  static String _cleanCueText(String value) => value
      .replaceAll(RegExp(r'<\/?(?:font|i|b|u|s|c|v|ruby|rt)[^>]*>', caseSensitive: false), '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

extension on String {
  bool equalsIgnoreCase(String other) => toLowerCase() == other.toLowerCase();
}
