import 'dart:convert';
import 'dart:io';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../models/external_subtitles.dart';

/// Persistent, per-title cache for downloaded external subtitles.
///
/// The subtitle bytes and their display metadata are stored separately from
/// expiring provider URLs. This lets the player restore language labels and
/// local subtitle tracks when a cached video stream is reused in a new session.
class SubtitlePlaybackStore {
  SubtitlePlaybackStore({Future<Directory> Function()? supportDirectory})
      : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;

  static const int _maxTracksPerMedia = 10;
  static const int _maxSubtitleTextBytes = 12 * 1024 * 1024;

  Future<List<CachedSubtitleTrack>> read(String mediaKey) async {
    try {
      final directory = await _mediaDirectory(mediaKey);
      final manifest = File('${directory.path}/tracks.json');
      if (!await manifest.exists()) return const <CachedSubtitleTrack>[];
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map || decoded['tracks'] is! List) {
        return const <CachedSubtitleTrack>[];
      }

      final tracks = <CachedSubtitleTrack>[];
      final retained = <Map<String, dynamic>>[];
      for (final item in (decoded['tracks'] as List).whereType<Map>()) {
        final row = Map<String, dynamic>.from(item);
        final fileName = row['fileName']?.toString() ?? '';
        if (!_isSafeFileName(fileName)) continue;
        final file = File('${directory.path}/$fileName');
        if (!await file.exists()) continue;
        final size = await file.length();
        if (size <= 0 || size > _maxSubtitleTextBytes) {
          await _deleteQuietly(file);
          continue;
        }
        final text = await file.readAsString();
        if (!text.trimLeft().startsWith('WEBVTT') ||
            !text.contains('-->')) {
          await _deleteQuietly(file);
          continue;
        }
        final track = CachedSubtitleTrack.fromJson(row, file.path);
        tracks.add(track);
        retained.add(row);
      }
      if (retained.length != (decoded['tracks'] as List).length) {
        await _writeManifest(directory, retained);
      }
      tracks.sort((a, b) => b.savedAt.compareTo(a.savedAt));
      return List<CachedSubtitleTrack>.unmodifiable(tracks);
    } catch (_) {
      // A broken cache must never prevent video playback.
      return const <CachedSubtitleTrack>[];
    }
  }

  Future<CachedSubtitleTrack> save({
    required String mediaKey,
    required ExternalSubtitle subtitle,
    required String webVtt,
  }) async {
    final content = webVtt.trim();
    if (!content.startsWith('WEBVTT') || !content.contains('-->')) {
      throw const FormatException('Only valid WebVTT subtitles can be cached.');
    }
    if (utf8.encode(content).length > _maxSubtitleTextBytes) {
      throw const FormatException('Subtitle is too large to cache.');
    }

    final directory = await _mediaDirectory(mediaKey);
    final cacheId = subtitle.id.trim().isEmpty
        ? '${subtitle.source}_${subtitle.language}_'
            '${sha256.convert(utf8.encode(subtitle.url)).toString()}'
        : subtitle.id.trim();
    final id = _safeComponent(cacheId);
    final fileName = '$id.vtt';
    final destination = File('${directory.path}/$fileName');
    final temporary = File('${directory.path}/$fileName.tmp');
    await temporary.writeAsString('$content\n', flush: true);
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);

    final existing = await _readManifestRows(directory);
    existing.removeWhere((row) => row['id']?.toString() == cacheId);
    final row = <String, dynamic>{
      'id': cacheId,
      'language': _normaliseLanguage(subtitle.language),
      'display': subtitle.display,
      'source': subtitle.source,
      'format': subtitle.format,
      'release': subtitle.release,
      'isHearingImpaired': subtitle.isHearingImpaired,
      'fileName': fileName,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
    };
    existing.insert(0, row);
    while (existing.length > _maxTracksPerMedia) {
      final removed = existing.removeLast();
      final removedName = removed['fileName']?.toString() ?? '';
      if (_isSafeFileName(removedName)) {
        await _deleteQuietly(File('${directory.path}/$removedName'));
      }
    }
    await _writeManifest(directory, existing);
    return CachedSubtitleTrack.fromJson(row, destination.path);
  }

  Future<Directory> _mediaDirectory(String mediaKey) async {
    final root = await _supportDirectory();
    final directory = Directory(
      '${root.path}/cinestream_subtitles/${_safeComponent(mediaKey)}',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<List<Map<String, dynamic>>> _readManifestRows(
    Directory directory,
  ) async {
    final manifest = File('${directory.path}/tracks.json');
    if (!await manifest.exists()) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is Map && decoded['tracks'] is List) {
        return (decoded['tracks'] as List)
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
      }
    } catch (_) {}
    return <Map<String, dynamic>>[];
  }

  Future<void> _writeManifest(
    Directory directory,
    List<Map<String, dynamic>> rows,
  ) async {
    final destination = File('${directory.path}/tracks.json');
    final temporary = File('${directory.path}/tracks.json.tmp');
    await temporary.writeAsString(
      jsonEncode(<String, dynamic>{'version': 1, 'tracks': rows}),
      flush: true,
    );
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);
  }

  static String _safeComponent(String input) {
    final safe = input.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return safe.isEmpty ? 'subtitle' : safe.substring(0, safe.length > 96 ? 96 : safe.length);
  }

  static bool _isSafeFileName(String value) =>
      value.isNotEmpty &&
      !value.contains('/') &&
      !value.contains('\\') &&
      value.toLowerCase().endsWith('.vtt');

  static String _normaliseLanguage(String value) {
    final code = value.trim().toLowerCase().split(RegExp(r'[-_]')).first;
    if (code == 'ara' || code == 'arabic') return 'ar';
    if (code == 'eng' || code == 'english') return 'en';
    return code;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

class CachedSubtitleTrack {
  const CachedSubtitleTrack({
    required this.id,
    required this.language,
    required this.display,
    required this.source,
    required this.format,
    required this.release,
    required this.isHearingImpaired,
    required this.filePath,
    required this.savedAt,
  });

  final String id;
  final String language;
  final String display;
  final String source;
  final String format;
  final String release;
  final bool isHearingImpaired;
  final String filePath;
  final DateTime savedAt;

  factory CachedSubtitleTrack.fromJson(
    Map<String, dynamic> json,
    String filePath,
  ) {
    return CachedSubtitleTrack(
      id: json['id']?.toString() ?? '',
      language: json['language']?.toString() ?? '',
      display: json['display']?.toString() ?? 'Unknown',
      source: json['source']?.toString() ?? '',
      format: json['format']?.toString() ?? 'vtt',
      release: json['release']?.toString() ?? '',
      isHearingImpaired: json['isHearingImpaired'] == true,
      filePath: filePath,
      savedAt: DateTime.tryParse(json['savedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  BetterPlayerSubtitlesSource toPlayerSource({
    bool selectedByDefault = false,
  }) {
    final label = display.trim().isEmpty ? language : display.trim();
    final name = <String>[
      label,
      if (isHearingImpaired && !label.toLowerCase().contains('hi')) 'HI',
      if (source.trim().isNotEmpty) source.trim(),
    ].join(' · ');
    return BetterPlayerSubtitlesSource(
      type: BetterPlayerSubtitlesSourceType.file,
      urls: <String>[filePath],
      name: name,
      selectedByDefault: selectedByDefault,
    );
  }
}
