import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flixquest/services/subtitle_file_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SubtitleFileNormalizer', () {
    test('converts SRT timestamps to WebVTT', () {
      const srt = '1\r\n00:00:01,250 --> 00:00:03,500\r\nHello world\r\n';
      final result = SubtitleFileNormalizer.normalizeBytes(utf8.encode(srt));
      expect(result, startsWith('WEBVTT'));
      expect(result, contains('00:00:01.250 --> 00:00:03.500'));
      expect(result, contains('Hello world'));
    });

    test('keeps an existing WebVTT file valid', () {
      const vtt = 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n';
      final result = SubtitleFileNormalizer.normalizeBytes(utf8.encode(vtt));
      expect(result, startsWith('WEBVTT'));
      expect(result, contains('Hello'));
    });

    test('decompresses gzip-wrapped SRT from OpenSubtitles', () {
      const srt = '1\n00:00:01,000 --> 00:00:02,000\nCompressed cue\n';
      final compressed = gzip.encode(utf8.encode(srt));
      final result = SubtitleFileNormalizer.normalizeBytes(compressed);
      expect(result, contains('Compressed cue'));
      expect(result, contains('00:00:01.000 --> 00:00:02.000'));
    });

    test('extracts SRT from a SubSource ZIP archive', () {
      const srt = '1\n00:00:01,000 --> 00:00:02,000\nSubSource cue\n';
      final sourceBytes = Uint8List.fromList(utf8.encode(srt));
      final archive = Archive()
        ..addFile(ArchiveFile('captions.srt', sourceBytes.length, sourceBytes));
      final zipped = ZipEncoder().encodeBytes(archive);

      final result = SubtitleFileNormalizer.normalizeBytes(zipped);
      expect(result, startsWith('WEBVTT'));
      expect(result, contains('SubSource cue'));
      expect(result, contains('00:00:01.000 --> 00:00:02.000'));
    });

    test('decodes legacy Windows-1252 punctuation correctly', () {
      final bytes = <int>[
        ...utf8.encode('00:00:01,000 --> 00:00:02,000\n'),
        0x93,
        ...utf8.encode('Quoted text'),
        0x94,
      ];
      final result = SubtitleFileNormalizer.normalizeBytes(bytes);
      expect(result, contains('“Quoted text”'));
    });

    test('converts ASS dialogue events to WebVTT', () {
      const ass = '''
[Script Info]
Title: Test
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,First line\\NSecond line
''';
      final result = SubtitleFileNormalizer.normalizeBytes(utf8.encode(ass));
      expect(result, contains('00:00:01.000 --> 00:00:02.500'));
      expect(result, contains('First line\nSecond line'));
    });

    test('rejects HTML/error pages instead of applying them as subtitles', () {
      expect(
        () => SubtitleFileNormalizer.normalizeBytes(
          utf8.encode('<html><body>Access denied</body></html>'),
        ),
        throwsFormatException,
      );
    });
  });
}
