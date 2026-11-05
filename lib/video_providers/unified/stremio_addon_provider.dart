import 'dart:convert';

import 'package:dio/dio.dart';

import 'media_identity.dart';
import 'source_manifest.dart';
import 'stream_option.dart';

/// Direct-stream adapter for the public Stremio add-on protocol.
///
/// Torrent, YouTube and external-link entries are deliberately not reported as
/// playable because FlixQuest has no torrent/debrid engine or external-link
/// resolver in this adapter. Only streams carrying a direct HTTP(S) `url` are
/// returned to the playback layer.
class StremioAddonProvider {
  StremioAddonProvider({Dio? dio}) : _dio = dio ?? _createDio();

  final Dio _dio;

  static Dio _createDio() => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 12),
          responseType: ResponseType.json,
          headers: const <String, String>{
            'Accept': 'application/json',
            'User-Agent': 'FlixQuest-SourceEngine/1.0',
          },
        ),
      );

  Future<List<UnifiedStreamOption>> getStreams({
    required SourceManifest source,
    required MediaIdentity media,
    CancelToken? cancelToken,
  }) async {
    if (source.engine.kind != SourceEngineKind.stremio) {
      throw ArgumentError.value(
        source.engine.rawType,
        'source.engine.kind',
        'The source is not a Stremio add-on.',
      );
    }
    if (!_supportsType(source, media.stremioType)) return const [];
    final candidateIds = _candidateIds(source, media);
    if (candidateIds.isEmpty) {
      final prefixes = source.engine.config['idPrefixes'];
      final acceptedPrefixes = prefixes is List
          ? (prefixes.isEmpty
              ? '(none declared)'
              : prefixes.map((value) => value.toString()).join(', '))
          : 'IMDb (Stremio default)';
      throw FormatException(
        'No matching external media ID is available for ${source.name}. '
        'The add-on accepts: $acceptedPrefixes. '
        'Resolve TMDB external_ids or provide a matching provider ID.',
      );
    }

    final results = <UnifiedStreamOption>[];
    final seen = <String>{};
    for (final videoId in candidateIds) {
      final uri = _streamUri(source.engine.endpoint, media, videoId);
      final response = await _dio.get<dynamic>(
        uri.toString(),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.json,
          validateStatus: (status) => status != null && status >= 200 && status < 300,
        ),
      );
      final body = _decodeObject(response.data);
      final rawStreams = body?['streams'];
      if (rawStreams is! List) continue;
      for (var index = 0; index < rawStreams.length; index++) {
        final rawStream = rawStreams[index];
        if (rawStream is! Map) continue;
        final stream = Map<String, dynamic>.from(rawStream);
        final url = _nonEmptyString(stream['url']);
        if (url == null || !_isHttpUrl(url)) continue;
        final behaviorHints = _asMap(stream['behaviorHints']);
        final proxyHeaders = _asMap(behaviorHints?['proxyHeaders']);
        final requestHeaders = _stringMap(proxyHeaders?['request']);
        final explicitHeaders = _stringMap(stream['headers']);
        final headers = <String, String>{...requestHeaders, ...explicitHeaders};
        final subtitles = _parseSubtitles(
          stream['subtitles'],
          fallbackHeaders: headers,
        );
        final subtitleKey = subtitles.map((subtitle) {
          final subtitleHeaders = subtitle.headers.entries
              .map((entry) => '${entry.key.toLowerCase()}:${entry.value}')
              .toList()
            ..sort();
          return <String>[
            subtitle.url,
            subtitle.language,
            subtitle.format ?? '',
            subtitle.isDefault.toString(),
            subtitleHeaders.join('&'),
          ].join(':');
        }).toList()
          ..sort();
        final headerKey = headers.entries
            .map((entry) => '${entry.key.toLowerCase()}:${entry.value}')
            .toList()
          ..sort();
        final displayParts = <String>[
          if (_nonEmptyString(stream['name']) != null)
            _nonEmptyString(stream['name'])!,
          if (_nonEmptyString(stream['title']) != null)
            _nonEmptyString(stream['title'])!,
          if (_nonEmptyString(stream['description']) != null)
            _nonEmptyString(stream['description'])!,
        ];
        final label = displayParts.isEmpty
            ? source.name
            : displayParts.join(' · ');
        final quality = _extractQuality(label) ??
            _extractQuality(_nonEmptyString(behaviorHints?['filename']) ?? '');
        final audioKind = _audioKind(label);
        final audioLanguage = _audioLanguage(label);
        final resolution = _parseResolution(label);
        final container = _containerFromUrl(url);
        final dedupeKey = <String>[
          url,
          headerKey.join('&'),
          label,
          quality ?? '',
          audioKind.name,
          audioLanguage ?? '',
          subtitleKey.join('|'),
        ].join('\u001f');
        if (!seen.add(dedupeKey)) continue;

        results.add(
          UnifiedStreamOption(
            id: '${source.stableKey}::${videoId}::$index',
            providerId: source.stableKey,
            providerName: source.name,
            url: url,
            label: label,
            quality: quality,
            width: resolution.$1,
            height: resolution.$2,
            container: container,
            headers: headers,
            audioKind: audioKind,
            audioLanguage: audioLanguage,
            subtitles: subtitles,
            isPlayable: true,
            metadata: <String, dynamic>{
              if (stream['name'] != null) 'name': stream['name'],
              if (stream['title'] != null) 'title': stream['title'],
              if (behaviorHints?['filename'] != null)
                'filename': behaviorHints!['filename'],
              if (behaviorHints?['notWebReady'] != null)
                'notWebReady': behaviorHints!['notWebReady'],
              'sourceIndex': index,
            },
          ),
        );
      }
      if (results.isNotEmpty) break;
    }
    return results;
  }

  List<String> _candidateIds(SourceManifest source, MediaIdentity media) {
    final configuredPrefixes = source.engine.config['idPrefixes'];
    final prefixes = configuredPrefixes is List
        ? configuredPrefixes.map((value) => value.toString().toLowerCase()).toList()
        : null;
    final ids = <String>[];

    final explicit = media.explicitStremioId;
    if (explicit != null && _acceptsIdentifier(explicit, prefixes)) {
      final explicitVideoId = media.isEpisode
          ? media.stremioId ?? explicit
          : explicit;
      ids.add(explicitVideoId);
    }

    final imdb = media.imdbId;
    if (imdb != null && _acceptsIdentifier(imdb, prefixes)) {
      final suffix = media.isEpisode
          ? ':${media.seasonNumber}:${media.episodeNumber}'
          : '';
      final imdbVideoId = '$imdb$suffix';
      if (!ids.contains(imdbVideoId)) ids.add(imdbVideoId);
    }

    final tmdb = media.tmdbId;
    if (tmdb != null && _acceptsIdentifier('tmdb:$tmdb', prefixes)) {
      final suffix = media.isEpisode
          ? ':${media.seasonNumber}:${media.episodeNumber}'
          : '';
      final tmdbVideoId = 'tmdb:$tmdb$suffix';
      if (!ids.contains(tmdbVideoId)) ids.add(tmdbVideoId);
    }

    // Stremio add-ons can advertise ecosystem-specific prefixes such as
    // `kitsu:` or `anilist:`. Use only identifiers explicitly supplied by the
    // catalogue/mapping layer and only when the add-on declares that prefix.
    for (final entry in media.externalIds.entries) {
      final key = entry.key.trim().toLowerCase();
      if (key.isEmpty || key == 'imdb' || key == 'imdbid' || key == 'stremio') {
        continue;
      }
      final value = entry.value.trim();
      if (value.isEmpty) continue;
      final candidate = value.contains(':') ? value : '$key:$value';
      if (!_acceptsIdentifier(candidate, prefixes)) continue;
      final suffix = media.isEpisode
          ? ':${media.seasonNumber}:${media.episodeNumber}'
          : '';
      final videoId = media.isEpisode && !candidate.endsWith(suffix)
          ? '$candidate$suffix'
          : candidate;
      if (!ids.contains(videoId)) ids.add(videoId);
    }
    return ids;
  }

  bool _acceptsIdentifier(String id, List<String>? prefixes) {
    // Stremio's default convention is IMDb IDs. TMDB IDs are only sent when
    // the add-on explicitly advertises a matching idPrefix in its manifest.
    if (prefixes == null) return id.startsWith('tt');
    if (prefixes.isEmpty) return false;
    return prefixes.any((prefix) {
      if (prefix == 'imdb') return id.startsWith('tt');
      return id.toLowerCase().startsWith(prefix);
    });
  }

  Uri _streamUri(String endpoint, MediaIdentity media, String videoId) {
    final base = Uri.tryParse(endpoint);
    if (base == null ||
        (base.scheme != 'https' && base.scheme != 'http') ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty) {
      throw const FormatException('Stremio add-on endpoint must be an HTTP(S) URL.');
    }
    final segments = base.pathSegments.where((segment) => segment.isNotEmpty).toList();
    segments.addAll(<String>['stream', media.stremioType, '$videoId.json']);
    return base.replace(pathSegments: segments);
  }

  bool _supportsType(SourceManifest source, String type) {
    final rawTypes = source.engine.config['types'];
    if (rawTypes is! List) return true;
    return rawTypes.any((value) => value.toString().toLowerCase() == type);
  }

  Map<String, dynamic>? _decodeObject(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.trim().isNotEmpty) {
      final decoded = jsonDecode(data);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    return null;
  }

  List<UnifiedSubtitleTrack> _parseSubtitles(
    dynamic raw, {
    Map<String, String> fallbackHeaders = const <String, String>{},
  }) {
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((item) {
      final subtitle = Map<String, dynamic>.from(item);
      return UnifiedSubtitleTrack(
        url: _nonEmptyString(subtitle['url']) ??
            _nonEmptyString(subtitle['file']) ??
            '',
        language: _nonEmptyString(subtitle['lang']) ??
            _nonEmptyString(subtitle['language']) ??
            'und',
        label: _nonEmptyString(subtitle['label']) ??
            _nonEmptyString(subtitle['name']),
        format: _nonEmptyString(subtitle['format']),
        headers: <String, String>{
          ...fallbackHeaders,
          ..._stringMap(subtitle['headers']),
        },
        isDefault: subtitle['default'] == true,
      );
    }).where((subtitle) => _isHttpUrl(subtitle.url)).toList(growable: false);
  }

  bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  String? _nonEmptyString(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  Map<String, dynamic>? _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;

  Map<String, String> _stringMap(dynamic value) {
    if (value is! Map) return const <String, String>{};
    return <String, String>{
      for (final entry in value.entries)
        if (entry.value != null) entry.key.toString(): entry.value.toString(),
    };
  }

  StreamContainer _containerFromUrl(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    if (path.endsWith('.m3u8')) return StreamContainer.hls;
    if (path.endsWith('.mpd')) return StreamContainer.dash;
    if (path.endsWith('.mp4') || path.endsWith('.m4v')) {
      return StreamContainer.mp4;
    }
    if (path.endsWith('.webm')) return StreamContainer.webm;
    return StreamContainer.unknown;
  }

  String? _extractQuality(String value) {
    final match = RegExp(
      r'(2160p|1440p|1080p|720p|576p|480p|360p|4k|8k)',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return null;
    final result = match.group(1)!;
    return result.toLowerCase() == '4k' ? '2160p' : result.toLowerCase();
  }

  (int?, int?) _parseResolution(String value) {
    final match = RegExp(r'(\d{3,4})\s*[x×]\s*(\d{3,4})').firstMatch(value);
    if (match == null) return (null, null);
    return (int.tryParse(match.group(1)!), int.tryParse(match.group(2)!));
  }

  StreamAudioKind _audioKind(String value) {
    final lower = value.toLowerCase();
    if (RegExp(r'\b(dub|dubbed|dual audio)\b').hasMatch(lower)) {
      return StreamAudioKind.dub;
    }
    if (RegExp(r'\b(sub|subbed)\b').hasMatch(lower)) {
      return StreamAudioKind.sub;
    }
    if (RegExp(r'\b(raw)\b').hasMatch(lower)) return StreamAudioKind.raw;
    return StreamAudioKind.unknown;
  }

  String? _audioLanguage(String value) {
    final lower = value.toLowerCase();
    const languages = <String, String>{
      'english': 'en',
      'eng': 'en',
      'japanese': 'ja',
      'jap': 'ja',
      'arabic': 'ar',
      'hindi': 'hi',
      'german': 'de',
      'french': 'fr',
      'spanish': 'es',
      'korean': 'ko',
      'chinese': 'zh',
    };
    final matches = languages.entries
        .where((entry) =>
            RegExp('\\b${RegExp.escape(entry.key)}\\b').hasMatch(lower))
        .map((entry) => entry.value)
        .toSet();
    return matches.length == 1 ? matches.single : null;
  }
}
