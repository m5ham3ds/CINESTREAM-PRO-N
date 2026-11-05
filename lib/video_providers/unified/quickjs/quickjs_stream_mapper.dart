import '../source_manifest.dart';
import '../stream_option.dart';

List<UnifiedStreamOption> mapQuickJsVideoSources(
  SourceManifest source,
  dynamic raw, {
  String idPrefix = 'js',
}) {
  if (raw is! List) return const <UnifiedStreamOption>[];
  final streams = <UnifiedStreamOption>[];
  var index = 0;
  for (final element in raw.whereType<Map>()) {
    final item = Map<String, dynamic>.from(element);
    final url = _readString(item, const <String>['url', 'file', 'link']);
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      continue;
    }
    final subtitles = item['subtitles'] is List
        ? (item['subtitles'] as List)
            .whereType<Map>()
            .map((subtitle) => UnifiedSubtitleTrack.fromJson(Map<String, dynamic>.from(subtitle)))
            .where((subtitle) => subtitle.url.isNotEmpty)
            .toList(growable: false)
        : const <UnifiedSubtitleTrack>[];
    final headers = _stringMap(item['headers']);
    final kind = (item['kind'] ?? 'unknown').toString().toLowerCase();
    final audioKind = switch (kind) {
      'sub' || 'subbed' => StreamAudioKind.sub,
      'dub' || 'dubbed' => StreamAudioKind.dub,
      'raw' => StreamAudioKind.raw,
      _ => StreamAudioKind.unknown,
    };
    final containerText = (item['container'] ?? item['mimeType'] ?? '').toString().toLowerCase();
    final container = containerText.contains('m3u8') || containerText == 'hls'
        ? StreamContainer.hls
        : containerText.contains('mpd') || containerText == 'dash'
            ? StreamContainer.dash
            : containerText.contains('mp4')
                ? StreamContainer.mp4
                : containerText.contains('webm')
                    ? StreamContainer.webm
                    : StreamContainer.unknown;
    index++;
    streams.add(UnifiedStreamOption(
      id: '${source.id}-$idPrefix-$index-${url.hashCode}',
      providerId: source.stableKey,
      providerName: source.name,
      url: url,
      label: _readString(item, const <String>['label', 'name']).ifEmptyNull,
      quality: _readString(item, const <String>['quality', 'resolution']).ifEmptyNull,
      container: container,
      headers: headers,
      audioKind: audioKind,
      audioLanguage: _readString(item, const <String>['audioLang', 'audioLanguage', 'lang']).ifEmptyNull,
      subtitles: subtitles,
      subtitleOffsetSeconds: _asDouble(item['subtitleSkewSeconds'] ?? item['subtitleOffsetSeconds']),
      subtitleOffsetAfterSeconds: _asDouble(item['subtitleSkewAfterSeconds'] ?? item['subtitleOffsetAfterSeconds']),
      expiresAt: _asDateTime(item['expiresAt'] ?? item['expiry'] ?? item['expires']),
      proxyUrl: _readString(item, const <String>['proxyUrl', 'proxy']).ifEmptyNull,
      drmType: _readString(item, const <String>['drmType', 'drm']).ifEmptyNull,
      metadata: <String, dynamic>{
        if (item['skipSegments'] != null) 'skipSegments': item['skipSegments'],
        if (item['intro'] != null) 'intro': item['intro'],
        if (item['outro'] != null) 'outro': item['outro'],
      },
    ));
  }
  return streams;
}

String _readString(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key]?.toString().trim();
    if (value != null && value.isNotEmpty && value != 'null') return value;
  }
  return '';
}

Map<String, String> _stringMap(dynamic value) {
  if (value is! Map) return const <String, String>{};
  return <String, String>{
    for (final entry in value.entries)
      if (entry.value != null) entry.key.toString(): entry.value.toString(),
  };
}

double? _asDouble(dynamic value) => value is num ? value.toDouble() : double.tryParse('$value');

DateTime? _asDateTime(dynamic value) {
  if (value is DateTime) return value;
  if (value is num) {
    final millis = value > 1000000000000
        ? value.toInt()
        : (value * 1000).toInt();
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.tryParse(value.trim());
  }
  return null;
}

extension on String {
  String? get ifEmptyNull => trim().isEmpty ? null : trim();
}
