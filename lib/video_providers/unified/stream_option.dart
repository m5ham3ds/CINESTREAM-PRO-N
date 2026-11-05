/// Normalized media container understood by the unified playback boundary.
enum StreamContainer { hls, dash, mp4, webm, torrent, unknown }

/// Audio intent advertised by a source. `unknown` is not treated as sub or dub.
enum StreamAudioKind { sub, dub, raw, unknown }

class UnifiedSubtitleTrack {
  const UnifiedSubtitleTrack({
    required this.url,
    this.language = 'und',
    this.label,
    this.format,
    this.headers = const <String, String>{},
    this.isDefault = false,
  });

  final String url;
  final String language;
  final String? label;
  final String? format;
  final Map<String, String> headers;
  final bool isDefault;

  factory UnifiedSubtitleTrack.fromJson(Map<String, dynamic> json) {
    return UnifiedSubtitleTrack(
      url: (json['url'] ?? json['file'] ?? '').toString(),
      language: (json['language'] ?? json['lang'] ?? 'und').toString(),
      label: json['label']?.toString(),
      format: json['format']?.toString(),
      headers: _stringMap(json['headers']),
      isDefault: json['default'] == true || json['isDefault'] == true,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'language': language,
        if (label != null) 'label': label,
        if (format != null) 'format': format,
        if (headers.isNotEmpty) 'headers': headers,
        'default': isDefault,
      };
}

/// One selectable stream, not a quality-to-URL map.
///
/// Multiple mirrors may share the same quality. Keeping every option as a
/// first-class object preserves provider identity, headers, audio intent,
/// subtitles and expiry metadata all the way to the player adapter.
class UnifiedStreamOption {
  const UnifiedStreamOption({
    required this.id,
    required this.providerId,
    required this.providerName,
    required this.url,
    this.label,
    this.quality,
    this.width,
    this.height,
    this.container = StreamContainer.unknown,
    this.headers = const <String, String>{},
    this.audioKind = StreamAudioKind.unknown,
    this.audioLanguage,
    this.subtitles = const <UnifiedSubtitleTrack>[],
    this.subtitleOffsetSeconds,
    this.subtitleOffsetAfterSeconds,
    this.expiresAt,
    this.proxyUrl,
    this.drmType,
    this.isPlayable = true,
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final String providerId;
  final String providerName;
  final String url;
  final String? label;
  final String? quality;
  final int? width;
  final int? height;
  final StreamContainer container;
  final Map<String, String> headers;
  final StreamAudioKind audioKind;
  final String? audioLanguage;
  final List<UnifiedSubtitleTrack> subtitles;
  final double? subtitleOffsetSeconds;
  final double? subtitleOffsetAfterSeconds;
  final DateTime? expiresAt;
  final String? proxyUrl;
  /// Descriptive DRM scheme only. This model does not contain keys or attempt
  /// to bypass licensing; a playback engine must explicitly support the scheme.
  final String? drmType;
  final bool isPlayable;
  final Map<String, dynamic> metadata;

  bool get hasHeaders => headers.isNotEmpty;
  bool get hasSubtitles => subtitles.isNotEmpty;
  bool get isExpired =>
      expiresAt != null && !expiresAt!.isAfter(DateTime.now());

  factory UnifiedStreamOption.fromJson(Map<String, dynamic> json) {
    final rawSubtitles = json['subtitles'];
    final subtitleList = rawSubtitles is List
        ? rawSubtitles
            .whereType<Map>()
            .map((item) => UnifiedSubtitleTrack.fromJson(
                  Map<String, dynamic>.from(item),
                ))
            .where((item) => item.url.trim().isNotEmpty)
            .toList(growable: false)
        : const <UnifiedSubtitleTrack>[];

    return UnifiedStreamOption(
      id: (json['id'] ?? '').toString(),
      providerId: (json['providerId'] ?? '').toString(),
      providerName: (json['providerName'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      label: json['label']?.toString(),
      quality: json['quality']?.toString(),
      width: _asInt(json['width']),
      height: _asInt(json['height']),
      container: _containerFrom(json['container']?.toString()),
      headers: _stringMap(json['headers']),
      audioKind: _audioKindFrom(json['audioKind']?.toString()),
      audioLanguage: json['audioLanguage']?.toString(),
      subtitles: subtitleList,
      subtitleOffsetSeconds: _asDouble(json['subtitleOffsetSeconds']),
      subtitleOffsetAfterSeconds:
          _asDouble(json['subtitleOffsetAfterSeconds']),
      expiresAt: _asDateTime(json['expiresAt']),
      proxyUrl: json['proxyUrl']?.toString(),
      drmType: json['drmType']?.toString(),
      isPlayable: json['isPlayable'] != false,
      metadata: json['metadata'] is Map
          ? Map<String, dynamic>.from(json['metadata'] as Map)
          : const <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'providerId': providerId,
        'providerName': providerName,
        'url': url,
        if (label != null) 'label': label,
        if (quality != null) 'quality': quality,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        'container': container.name,
        if (headers.isNotEmpty) 'headers': headers,
        'audioKind': audioKind.name,
        if (audioLanguage != null) 'audioLanguage': audioLanguage,
        'subtitles': subtitles.map((item) => item.toJson()).toList(),
        if (subtitleOffsetSeconds != null)
          'subtitleOffsetSeconds': subtitleOffsetSeconds,
        if (subtitleOffsetAfterSeconds != null)
          'subtitleOffsetAfterSeconds': subtitleOffsetAfterSeconds,
        if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
        if (proxyUrl != null) 'proxyUrl': proxyUrl,
        if (drmType != null) 'drmType': drmType,
        'isPlayable': isPlayable,
        if (metadata.isNotEmpty) 'metadata': metadata,
      };
}

Map<String, String> _stringMap(dynamic value) {
  if (value is! Map) return const <String, String>{};
  return <String, String>{
    for (final entry in value.entries)
      if (entry.value != null)
        entry.key.toString(): entry.value.toString(),
  };
}

int? _asInt(dynamic value) => value is num ? value.toInt() : int.tryParse('$value');

double? _asDouble(dynamic value) =>
    value is num ? value.toDouble() : double.tryParse('$value');

DateTime? _asDateTime(dynamic value) {
  if (value is DateTime) return value;
  if (value is num) {
    final millis = value > 1000000000000 ? value.toInt() : (value * 1000).toInt();
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.tryParse(value.trim());
  }
  return null;
}

StreamContainer _containerFrom(String? value) {
  switch (value?.toLowerCase()) {
    case 'hls':
    case 'm3u8':
      return StreamContainer.hls;
    case 'dash':
    case 'mpd':
      return StreamContainer.dash;
    case 'mp4':
      return StreamContainer.mp4;
    case 'webm':
      return StreamContainer.webm;
    case 'torrent':
      return StreamContainer.torrent;
    default:
      return StreamContainer.unknown;
  }
}

StreamAudioKind _audioKindFrom(String? value) {
  switch (value?.toLowerCase()) {
    case 'sub':
    case 'subbed':
      return StreamAudioKind.sub;
    case 'dub':
    case 'dubbed':
      return StreamAudioKind.dub;
    case 'raw':
      return StreamAudioKind.raw;
    default:
      return StreamAudioKind.unknown;
  }
}
