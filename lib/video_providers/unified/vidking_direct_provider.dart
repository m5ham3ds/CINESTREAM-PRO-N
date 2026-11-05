import 'dart:convert';

import 'package:dio/dio.dart';

import '../../functions/video_utils.dart';

import 'media_identity.dart';
import 'source_manifest.dart';
import 'stream_option.dart';
import 'vidking_payload_cipher.dart';

/// Vidking direct API adapter based on OpenStream's MIT-licensed implementation.
/// The API host is intentionally fixed: repository entries may select a route,
/// but cannot redirect this engine to an arbitrary host.
class VidkingDirectProvider {
  VidkingDirectProvider({Dio? dio}) : _dio = dio ?? _createDio();

  static const String apiBaseUrl = 'https://api.speedracelight.com';
  static const String origin = 'https://www.vidking.net';
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  final Dio _dio;
  final Map<int, _SeedCacheEntry> _seedCache = <int, _SeedCacheEntry>{};
  final Map<int, Future<_SeedCacheEntry>> _seedRequests =
      <int, Future<_SeedCacheEntry>>{};

  static Dio _createDio() => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 12),
          followRedirects: true,
          maxRedirects: 5,
          responseType: ResponseType.plain,
          headers: const <String, String>{
            'Accept': 'application/json, text/plain, */*',
            'User-Agent': userAgent,
          },
        ),
      );

  Future<List<UnifiedStreamOption>> resolve({
    required SourceManifest source,
    required MediaIdentity media,
    CancelToken? cancelToken,
  }) async {
    final tmdbId = media.tmdbId;
    if (tmdbId == null || tmdbId <= 0) {
      throw const FormatException('Vidking requires a valid TMDB identifier.');
    }
    final route = _validatedRoute(source.engine.endpoint);
    final seed = await _seed(tmdbId, cancelToken: cancelToken);
    var response = await _requestSources(
      route: route,
      source: source,
      media: media,
      seed: seed,
      cancelToken: cancelToken,
    );

    if (response.statusCode == 401) {
      final refreshedSeed = await _seed(
        tmdbId,
        forceRefresh: true,
        cancelToken: cancelToken,
      );
      response = await _requestSources(
        route: route,
        source: source,
        media: media,
        seed: refreshedSeed,
        cancelToken: cancelToken,
      );
      return _decodeResponse(response, refreshedSeed.value, tmdbId, source);
    }
    return _decodeResponse(response, seed.value, tmdbId, source);
  }

  Future<Response<String>> _requestSources({
    required String route,
    required SourceManifest source,
    required MediaIdentity media,
    required _SeedCacheEntry seed,
    CancelToken? cancelToken,
  }) {
    final uri = Uri.parse('$apiBaseUrl/$route').replace(
      queryParameters: <String, String>{
        'title': media.title,
        'mediaType': media.type == UnifiedMediaType.movie ? 'movie' : 'tv',
        'year': media.year?.toString() ?? '',
        'episodeId': (media.episodeNumber ?? 1).toString(),
        'seasonId': (media.seasonNumber ?? 1).toString(),
        'tmdbId': media.tmdbId.toString(),
        'imdbId': media.imdbId ?? '',
        'enc': '2',
        'seed': seed.value,
        '_t': DateTime.now().millisecondsSinceEpoch.toString(),
        if (source.engine.language != null)
          'language': source.engine.language!,
      },
    );
    return _dio.get<String>(
      uri.toString(),
      cancelToken: cancelToken,
      options: Options(
        headers: <String, String>{
          'User-Agent': userAgent,
          'Referer': '$origin/',
          'Origin': origin,
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
        },
        validateStatus: (status) => status != null,
        responseType: ResponseType.plain,
      ),
    );
  }

  Future<_SeedCacheEntry> _seed(
    int mediaId, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    // Every direct route for one title shares a seed. If several endpoints
    // answer 401 together, only one refreshed seed request may be in flight;
    // parallel refreshes can otherwise invalidate one another at the API.
    final inFlight = _seedRequests[mediaId];
    if (inFlight != null) return inFlight;
    final now = DateTime.now();
    final cached = _seedCache[mediaId];
    if (!forceRefresh && cached != null &&
        cached.expiresAt.isAfter(now.add(const Duration(seconds: 5)))) {
      return cached;
    }

    final request = () async {
      final uri = Uri.parse('$apiBaseUrl/seed').replace(
        queryParameters: <String, String>{'mediaId': mediaId.toString()},
      );
      final response = await _dio.get<String>(
        uri.toString(),
        cancelToken: cancelToken,
        options: Options(validateStatus: (status) => status != null),
      );
      if ((response.statusCode ?? 500) < 200 ||
          (response.statusCode ?? 500) >= 300) {
        throw DioException(
          requestOptions: response.requestOptions,
          response: response,
          message: 'Vidking seed endpoint returned HTTP ${response.statusCode}.',
        );
      }
      final decoded = jsonDecode(response.data ?? '') as Map<String, dynamic>;
      final value = (decoded['seed'] ?? '').toString();
      if (value.isEmpty) throw const FormatException('Vidking seed is empty.');
      final ttlMs = (decoded['ttlMs'] as num?)?.toInt() ?? 30000;
      final entry = _SeedCacheEntry(
        value: value,
        expiresAt: DateTime.now().add(Duration(milliseconds: ttlMs.clamp(1000, 300000).toInt())),
      );
      _seedCache[mediaId] = entry;
      return entry;
    }();
    _seedRequests[mediaId] = request;
    try {
      return await request;
    } finally {
      if (identical(_seedRequests[mediaId], request)) {
        _seedRequests.remove(mediaId);
      }
    }
  }

  List<UnifiedStreamOption> _decodeResponse(
    Response<String> response,
    String seed,
    int mediaId,
    SourceManifest source,
  ) {
    final status = response.statusCode ?? 500;
    if (status < 200 || status >= 300) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: '${source.name} returned HTTP $status.',
      );
    }
    final body = response.data ?? '';
    if (body.trim().isEmpty) throw const FormatException('Vidking payload is empty.');
    final decoded = jsonDecode(
      VidkingPayloadCipher.decrypt(body, seed, mediaId),
    );
    if (decoded is! Map) {
      throw FormatException(
        '${source.name} returned HTTP $status, but the decrypted payload was not a JSON object.',
      );
    }
    final payload = Map<String, dynamic>.from(decoded);
    final streams = _toStreams(payload, source);
    if (streams.isEmpty) {
      final rawSources = payload['sources'];
      final sourceCount = rawSources is List ? rawSources.length : 0;
      final playlist = (payload['playlist'] ?? '').toString();
      final hasPlaylist = _isPublicHttpUrl(playlist);
      final qualityFilter = source.engine.qualityFilter?.trim();
      throw FormatException(
        '${source.name} returned HTTP $status but no usable stream. '
        'sourceEntries=$sourceCount, masterPlaylist=${hasPlaylist ? 'present' : 'absent'}'
        '${qualityFilter == null || qualityFilter.isEmpty ? '' : ', qualityFilter=$qualityFilter'}.',
      );
    }
    return streams;
  }

  List<UnifiedStreamOption> _toStreams(
    Map<String, dynamic> payload,
    SourceManifest source,
  ) {
    final rawSources = payload['sources'];
    final rawSubtitles = payload['subtitles'];
    final sources = rawSources is List
        ? rawSources.whereType<Map>().map((entry) => Map<String, dynamic>.from(entry)).toList()
        : <Map<String, dynamic>>[];
    final subtitles = <UnifiedSubtitleTrack>[
      if (rawSubtitles is List)
        for (final raw in rawSubtitles.whereType<Map>())
          if ((raw['url'] ?? '').toString().startsWith('http'))
            UnifiedSubtitleTrack(
              url: (raw['url']).toString(),
              language: (raw['lang'] ?? 'und').toString(),
              label: (raw['label'] ?? raw['lang'] ?? 'Subtitle').toString(),
              headers: _requestHeaders,
            ),
    ];

    final qualityFilter = source.engine.qualityFilter?.trim();
    final playlist = (payload['playlist'] ?? '').toString();
    if ((Uri.tryParse(playlist)?.scheme == 'https' ||
            Uri.tryParse(playlist)?.scheme == 'http') &&
        Uri.tryParse(playlist)?.host.isNotEmpty == true &&
        qualityFilter == null &&
        sources.isNotEmpty) {
      final qualities = sources
          .map((entry) => (entry['quality'] ?? '').toString())
          .where((value) => value.isNotEmpty)
          .toList();
      final best = qualities.isEmpty ? 'Auto' : _bestQuality(qualities);
      return <UnifiedStreamOption>[
        UnifiedStreamOption(
          id: 'vidking-${source.id}-master',
          providerId: 'vidking-${source.id}',
          providerName: source.name,
          url: playlist,
          label: '${source.name} · Adaptive',
          quality: best,
          container: StreamContainer.hls,
          headers: _requestHeaders,
          audioKind: _audioKind(source.engine.language),
          audioLanguage: source.engine.language ?? 'und',
          subtitles: subtitles,
          metadata: <String, dynamic>{
            'adaptiveMaster': true,
            'availableHeights': qualities
                .map(_qualityHeight)
                .whereType<int>()
                .toSet()
                .toList(growable: false),
          },
        ),
      ];
    }

    final output = <UnifiedStreamOption>[];
    for (var index = 0; index < sources.length; index++) {
      final entry = sources[index];
      final url = (entry['url'] ?? '').toString().trim();
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'https' && uri.scheme != 'http') ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        continue;
      }
      final rawQuality = (entry['quality'] ?? 'Auto').toString();
      if (qualityFilter != null &&
          rawQuality.toLowerCase() != qualityFilter.toLowerCase()) {
        continue;
      }
      final sourceType = (entry['type'] ?? '').toString().toLowerCase();
      final container = _container(url, sourceType);
      final audioDescription = <String>[
        sourceType,
        source.engine.language ?? '',
        qualityFilter ?? '',
      ].where((value) => value.isNotEmpty).join(' ');
      final audioLanguage = source.engine.qualityFilter ?? source.engine.language;
      output.add(
        UnifiedStreamOption(
          id: 'vidking-${source.id}-$index-${url.hashCode}',
          providerId: 'vidking-${source.id}',
          providerName: source.name,
          url: url,
          label: '${source.name} · $rawQuality',
          quality: rawQuality,
          height: _qualityHeight(rawQuality),
          container: container,
          headers: _requestHeaders,
          audioKind: _audioKind(audioDescription),
          audioLanguage: audioLanguage,
          subtitles: subtitles,
          metadata: <String, dynamic>{
            'sourceType': sourceType,
            'isDownloadable': !url.split('?').first.toLowerCase().endsWith('.mpd'),
          },
        ),
      );
    }
    return output;
  }

  static const Map<String, String> _requestHeaders = <String, String>{
    'User-Agent': userAgent,
    'Referer': '$origin/',
    'Origin': origin,
  };

  static String _validatedRoute(String endpoint) {
    final value = endpoint.trim().replaceAll('\\', '/');
    final uri = Uri.tryParse(value);
    if (value.isEmpty ||
        uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        value.startsWith('/') ||
        uri.pathSegments.any((segment) => segment == '..' || segment == '.')) {
      throw const FormatException('Vidking route is invalid.');
    }
    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
    if (segments.isEmpty) throw const FormatException('Vidking route is empty.');
    return segments.join('/');
  }

  static bool _isPublicHttpUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  static StreamContainer _container(String url, String sourceType) {
    final lower = url.toLowerCase().split('?').first;
    if (sourceType.contains('m3u8') || lower.endsWith('.m3u8')) return StreamContainer.hls;
    if (sourceType.contains('mpd') || lower.endsWith('.mpd')) return StreamContainer.dash;
    if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) return StreamContainer.mp4;
    if (lower.endsWith('.webm')) return StreamContainer.webm;
    return StreamContainer.unknown;
  }

  static StreamAudioKind _audioKind(String? value) {
    final lower = (value ?? '').toLowerCase();
    if (lower.contains('dub')) return StreamAudioKind.dub;
    if (lower.contains('sub')) return StreamAudioKind.sub;
    if (lower.contains('raw')) return StreamAudioKind.raw;
    return StreamAudioKind.unknown;
  }

  static String _bestQuality(List<String> values) {
    int rank(String value) => _qualityHeight(value) ?? 0;
    return values.reduce((a, b) => rank(a) >= rank(b) ? a : b);
  }

  static int? _qualityHeight(String value) =>
      VideoUtils.videoQualityHeight(value);
}

class _SeedCacheEntry {
  const _SeedCacheEntry({required this.value, required this.expiresAt});

  final String value;
  final DateTime expiresAt;
}
