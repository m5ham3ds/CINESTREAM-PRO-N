import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flixquest/api/endpoints.dart';
import 'package:flixquest/core/cache/cache_policy.dart';
import 'package:flixquest/core/network/network_runtime.dart';
import 'package:flutter/services.dart';

import 'media_identity.dart';
import 'quickjs/crypto_ops.dart';
import 'quickjs/quickjs_provider_runtime.dart';
import 'quickjs/quickjs_stream_mapper.dart';
import 'source_engine.dart';
import 'source_manifest.dart';
import 'stream_option.dart';

class _AnimeEpisodeRef {
  const _AnimeEpisodeRef({
    required this.anilistId,
    required this.episode,
    this.malId,
    this.titles = const <String>[],
  });
  final int anilistId;
  final int episode;
  final int? malId;
  final List<String> titles;
}

class _AnimeEpisodeMapping {
  const _AnimeEpisodeMapping({
    required this.anilistEpisode,
    this.season,
    this.number,
    this.airDate,
  });

  final int anilistEpisode;
  final int? season;
  final int? number;
  final String? airDate;
}

class _AnimeEntry {
  const _AnimeEntry({
    required this.id,
    required this.titles,
    required this.episodes,
    this.malId,
    this.episodeCount,
    this.sequelId,
  });

  final int id;
  final List<String> titles;
  final List<_AnimeEpisodeMapping> episodes;
  final int? malId;
  final int? episodeCount;
  final int? sequelId;

  _AnimeEpisodeRef ref(int episode) => _AnimeEpisodeRef(
        anilistId: id,
        episode: episode,
        malId: malId,
        titles: titles,
      );
}

/// Port of the OpenStream anime source family. ReAnime, FourAnimo and AnimeGG
/// are implemented here. Anikoto is supported through its AJAX + MegaPlay
/// route, with alternate hoster embeds handed to the bundled extractor registry
/// and Android WebView sniffer. AnimePahe mirrors OpenStream's hidden-WebView
/// cf_clearance flow; interactive Turnstile challenges remain unsupported.
typedef TmdbEpisodeAirDateLookup = Future<String?> Function(
  int tmdbId,
  int seasonNumber,
  int episodeNumber,
  CancelToken? cancelToken,
);

class OpenStreamAnimeSourceEngine extends SourceEngine {
  OpenStreamAnimeSourceEngine({
    Dio? dio,
    QuickJsProviderRuntime? quickJsRuntime,
    TmdbEpisodeAirDateLookup? episodeAirDateLookup,
  })  : _dio = dio ?? Dio(),
        _quickJsRuntime = quickJsRuntime ?? QuickJsProviderRuntime(dio: dio),
        _episodeAirDateLookup = episodeAirDateLookup ?? _lookupEpisodeAirDate;

  static const MethodChannel _webEmbedChannel =
      MethodChannel('flixquest/openstream_web_embed');
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const String _animePaheDefaultUserAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
  static const String _megaplayKey = 'i?LMTAx0Q6,:}50U';
  static const String _megaplayIv = "W0;27ToaUpl_P%'c";

  final Dio _dio;
  final QuickJsProviderRuntime _quickJsRuntime;
  final TmdbEpisodeAirDateLookup _episodeAirDateLookup;
  final Map<String, _AnimeEpisodeRef?> _mappingCache = <String, _AnimeEpisodeRef?>{};
  final Map<String, Future<_AnimeEpisodeRef?>> _mappingInFlight =
      <String, Future<_AnimeEpisodeRef?>>{};
  final Map<int, _AnimeEntry> _entryCache = <int, _AnimeEntry>{};
  final Map<int, String> _animePaheSessionCache = <int, String>{};
  String? _animePaheCookie;
  String? _animePaheActiveUserAgent;
  DateTime? _animePaheCookieExpiresAt;

  static const Set<String> supportedTypes = <String>{
    'anikoto',
    'reanime',
    'animepahe',
    'fouranimo',
    'animegg',
  };

  @override
  SourceEngineKind get kind => SourceEngineKind.animeSite;

  @override
  bool supports(SourceManifest source) =>
      supportedTypes.contains(source.engine.rawType.toLowerCase());

  @override
  Future<UnifiedSourceResult> resolve({
    required SourceManifest source,
    required MediaIdentity media,
    CancelToken? cancelToken,
  }) async {
    final watch = Stopwatch()..start();
    try {
      if (!supports(source)) {
        throw FormatException(
          'OpenStream anime engine ${source.engine.rawType} is not implemented in this build.',
        );
      }
      // OpenStream's AnimeEpisodeMapper also resolves anime films: ani.zip
      // marks their TMDB mapping as MOVIE and the provider receives episode 1.
      // A regular film simply has no ani.zip/AniList mapping and returns no
      // streams, rather than being mistaken for a TV episode.
      if (media.type != UnifiedMediaType.movie && !media.isEpisode) {
        throw const FormatException(
          'OpenStream anime providers need a movie or a season/episode identity.',
        );
      }
      final ref = await _mapEpisode(media, cancelToken);
      if (ref == null) {
        throw const FormatException('TMDB/AniList mapping did not identify this anime episode.');
      }
      final streams = switch (source.engine.rawType.toLowerCase()) {
        'reanime' => await _reAnime(source, ref, cancelToken),
        'animepahe' => await _animePahe(source, ref, cancelToken),
        'fouranimo' => await _fourAnimo(source, ref, cancelToken),
        'animegg' => await _animeGg(source, media, ref, cancelToken),
        'anikoto' => await _anikoto(source, ref, cancelToken),
        _ => const <UnifiedStreamOption>[],
      };
      watch.stop();
      return UnifiedSourceResult(streams: streams, elapsed: watch.elapsed);
    } on DioException catch (error) {
      watch.stop();
      return UnifiedSourceResult(errorMessage: error.message ?? 'Anime source request failed.', elapsed: watch.elapsed);
    } catch (error) {
      watch.stop();
      return UnifiedSourceResult(errorMessage: error.toString(), elapsed: watch.elapsed);
    }
  }

  Future<_AnimeEpisodeRef?> _mapEpisode(MediaIdentity media, CancelToken? token) async {
    final explicit = int.tryParse(
      media.externalIds['anilist'] ?? media.externalIds['anilistId'] ?? '',
    );
    // Movie and TV TMDB IDs share the same numeric namespace. Include the
    // content type in the key so movie/42 cannot reuse TV/42's mapping.
    final cacheKey = '${media.type.name}:${media.tmdbId}:'
        '${media.seasonNumber}:${media.episodeNumber}:$explicit';
    if (_mappingCache.containsKey(cacheKey)) return _mappingCache[cacheKey];
    final pending = _mappingInFlight[cacheKey];
    if (pending != null) return pending;

    final future = _resolveEpisodeMapping(media, token);
    _mappingInFlight[cacheKey] = future;
    try {
      final mapped = await future;
      // Cache both matches and definitive misses. Thrown network errors are
      // not cached, so another provider can retry after a transient failure.
      _mappingCache[cacheKey] = mapped;
      return mapped;
    } finally {
      if (identical(_mappingInFlight[cacheKey], future)) {
        _mappingInFlight.remove(cacheKey);
      }
    }
  }

  Future<_AnimeEpisodeRef?> _resolveEpisodeMapping(
    MediaIdentity media,
    CancelToken? token,
  ) async {
    final explicit = int.tryParse(
      media.externalIds['anilist'] ?? media.externalIds['anilistId'] ?? '',
    );
    final isMovie = media.type == UnifiedMediaType.movie;
    var rootId = explicit;
    if (rootId == null) {
      final tmdbId = media.tmdbId;
      if (tmdbId == null || tmdbId <= 0) return null;
      final response = await _dio.get<dynamic>(
        'https://api.ani.zip/mappings',
        queryParameters: <String, dynamic>{'themoviedb_id': tmdbId},
        cancelToken: token,
        options: _jsonOptions,
      );
      final mappings = _map(response.data)['mappings'];
      if (mappings is Map) {
        final mappedType = (mappings['type'] ?? '').toString().toUpperCase();
        final mappingIsMovie = mappedType == 'MOVIE';
        if (mappingIsMovie == isMovie) {
          rootId = _int(mappings['anilist_id']);
        }
      }
    }
    if (rootId == null || rootId <= 0) return null;

    final root = await _loadAnimeEntry(rootId, token);
    if (root == null) return null;
    // OpenStream uses AniList's first episode slot for anime films. It does
    // not try to interpret the film as S1E1 of a TV series.
    if (isMovie) {
      final ref = root.ref(1);
      return ref;
    }

    // One TMDB series can span multiple AniList entries, one per season.
    // Walk SEQUEL relations with the same bounded/cycle-safe strategy as
    // OpenStream's AnimeEpisodeMapper instead of assuming season N is episode N.
    final chain = <_AnimeEntry>[root];
    final visited = <int>{root.id};
    var cursor = root;
    while (chain.length < 12) {
      final sequel = cursor.sequelId;
      if (sequel == null || sequel <= 0 || !visited.add(sequel)) break;
      final entry = await _loadAnimeEntry(sequel, token);
      if (entry == null) break;
      chain.add(entry);
      cursor = entry;
    }

    for (final entry in chain) {
      final match = entry.episodes.firstWhereOrNull(
        (episode) =>
            episode.season == media.seasonNumber &&
            episode.number == media.episodeNumber,
      );
      if (match != null) {
        final ref = entry.ref(match.anilistEpisode);
        return ref;
      }
    }

    // OpenStream also falls back to TMDB season metadata by air date. The TV
    // loader normally supplies episodeAirDate; query TMDB only when that date
    // is missing or did not match the ani.zip coordinates (specials and split
    // anime seasons are the common cases).
    final requestedAirDate = _normalizeAirDate(media.episodeAirDate);
    if (requestedAirDate != null) {
      final byProvidedDate = _findByAirDate(chain, requestedAirDate);
      if (byProvidedDate != null) {
        return byProvidedDate;
      }
    }
    try {
      final tmdbId = media.tmdbId;
      if (tmdbId != null && media.seasonNumber != null && media.episodeNumber != null) {
        final mappedAirDate = _normalizeAirDate(
          await _episodeAirDateLookup(
            tmdbId,
            media.seasonNumber!,
            media.episodeNumber!,
            token,
          ).timeout(const Duration(seconds: 8)),
        );
        if (mappedAirDate != null && mappedAirDate != requestedAirDate) {
          final byTmdbDate = _findByAirDate(chain, mappedAirDate);
          if (byTmdbDate != null) {
            return byTmdbDate;
          }
        }
      }
    } catch (_) {
      // Date mapping is an optional fallback. Keep the season/episode and
      // safe S1 sequential strategies available when TMDB is unavailable.
    }

    // Some single-entry shows have incomplete ani.zip episode coordinates.
    // Only use the sequential fallback for S1; later seasons must never be
    // silently mapped to the wrong episode.
    if (media.seasonNumber == 1 && chain.isNotEmpty) {
      final root = chain.first;
      if (root.episodeCount == null || media.episodeNumber! <= root.episodeCount!) {
        final ref = root.ref(media.episodeNumber!);
        return ref;
      }
    }

    return null;
  }

  static const CachePolicy _seasonDetailsCachePolicy = CachePolicy(
    scope: 'tmdb',
    fresh: Duration(days: 30),
    maxStale: Duration(days: 150),
  );

  static String? _normalizeAirDate(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.length < 10) return null;
    final date = trimmed.substring(0, 10);
    return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ? date : null;
  }

  _AnimeEpisodeRef? _findByAirDate(List<_AnimeEntry> chain, String airDate) {
    for (final entry in chain) {
      final match = entry.episodes.firstWhereOrNull(
        (episode) => episode.airDate == airDate,
      );
      if (match != null) return entry.ref(match.anilistEpisode);
    }
    return null;
  }

  static Future<String?> _lookupEpisodeAirDate(
    int tmdbId,
    int seasonNumber,
    int episodeNumber,
    CancelToken? cancelToken,
  ) async {
    final result = await NetworkRuntime.tmdb.getJson(
      Endpoints.getSeasonDetails(tmdbId, seasonNumber, 'en-US'),
      policy: _seasonDetailsCachePolicy,
      cancelToken: cancelToken,
      timeout: const Duration(seconds: 8),
    );
    final body = result.getOrElse((_) => const <String, dynamic>{});
    final rawEpisodes = body['episodes'];
    if (rawEpisodes is! List) return null;
    for (final rawEpisode in rawEpisodes.whereType<Map>()) {
      final number = int.tryParse(
        (rawEpisode['episode_number'] ?? rawEpisode['episodeNumber'] ?? '').toString(),
      );
      if (number != episodeNumber) continue;
      return _normalizeAirDate(rawEpisode['air_date']?.toString());
    }
    return null;
  }

  Future<_AnimeEntry?> _loadAnimeEntry(int anilistId, CancelToken? token) async {
    final cached = _entryCache[anilistId];
    if (cached != null) return cached;

    final graph = await _dio.post<dynamic>(
      'https://graphql.anilist.co',
      data: <String, dynamic>{
        'query': 'query(\$id:Int){Media(id:\$id,type:ANIME){id idMal episodes format title{romaji english} relations{edges{relationType node{id type format}}}}}',
        'variables': <String, dynamic>{'id': anilistId},
      },
      cancelToken: token,
      options: _jsonOptions,
    );
    final mediaData = _map(_map(graph.data)['data'])['Media'];
    if (mediaData is! Map) return null;

    final mappingsResponse = await _dio.get<dynamic>(
      'https://api.ani.zip/mappings',
      queryParameters: <String, dynamic>{'anilist_id': anilistId},
      cancelToken: token,
      options: _jsonOptions,
    );
    final rawEpisodes = _map(mappingsResponse.data)['episodes'];
    final episodes = <_AnimeEpisodeMapping>[];
    if (rawEpisodes is Map) {
      for (final item in rawEpisodes.entries) {
        final episodeNumber = int.tryParse(item.key.toString());
        if (episodeNumber == null || item.value is! Map) continue;
        final value = Map<String, dynamic>.from(item.value as Map);
        final rawAirDate = (value['airDate'] ?? value['airdate'])?.toString();
        episodes.add(_AnimeEpisodeMapping(
          anilistEpisode: episodeNumber,
          season: _int(value['seasonNumber']),
          number: _int(value['episodeNumber']),
          airDate: rawAirDate != null && rawAirDate.length >= 10
              ? rawAirDate.substring(0, 10)
              : null,
        ));
      }
    }

    final titleMap = mediaData['title'];
    final titles = <String>{};
    if (titleMap is Map) {
      for (final value in titleMap.values) {
        final title = value?.toString().trim() ?? '';
        if (title.isNotEmpty) titles.add(title);
      }
    }
    final relations = mediaData['relations'];
    final edges = relations is Map ? relations['edges'] : null;
    int? sequelId;
    if (edges is List) {
      for (final rawEdge in edges.whereType<Map>()) {
        if ((rawEdge['relationType'] ?? '').toString().toUpperCase() != 'SEQUEL') {
          continue;
        }
        final node = rawEdge['node'];
        if (node is! Map || (node['type'] ?? '').toString().toUpperCase() != 'ANIME') {
          continue;
        }
        final format = (node['format'] ?? '').toString().toUpperCase();
        if (!const <String>{'TV', 'TV_SHORT', 'ONA'}.contains(format)) continue;
        sequelId = _int(node['id']);
        if (sequelId != null) break;
      }
    }

    final entry = _AnimeEntry(
      id: anilistId,
      titles: titles.toList(growable: false),
      episodes: episodes,
      malId: _int(mediaData['idMal']),
      episodeCount: _int(mediaData['episodes']),
      sequelId: sequelId,
    );
    _entryCache[anilistId] = entry;
    return entry;
  }

  Future<List<UnifiedStreamOption>> _reAnime(
    SourceManifest source,
    _AnimeEpisodeRef ref,
    CancelToken? token,
  ) async {
    const origin = 'https://megaplay.buzz';
    final out = <UnifiedStreamOption>[];
    for (final audio in <String>['sub', 'dub']) {
      for (final server in <String>['tcdn', 'bcdn']) {
        final embed = '$origin/stream/ani/${ref.anilistId}/${ref.episode}/$audio?s=$server';
        try {
          final page = await _getText(embed, headers: <String, String>{'Referer': '${source.engine.endpoint}/'}, cancelToken: token);
          final id = RegExp(r'data-id="(\d+)"').firstMatch(page)?.group(1);
          if (id == null) continue;
          final data = await _getJson(
            '$origin/stream/getSourcesNew?id=$id&s=$server',
            headers: <String, String>{'Referer': embed, 'X-Requested-With': 'XMLHttpRequest'},
            cancelToken: token,
          );
          final encrypted = data['enc']?.toString();
          if (encrypted == null || encrypted.isEmpty) continue;
          final decrypted = _decryptMegaplay(encrypted);
          final file = decrypted['file']?.toString() ?? '';
          if (file.isEmpty) continue;
          final headers = <String, String>{'Referer': '$origin/', 'User-Agent': _userAgent};
          final playlist = await _getText(file, headers: headers, cancelToken: token);
          if (!playlist.trimLeft().startsWith('#EXTM3U')) continue;
          out.add(_stream(
            source: source,
            url: file,
            name: '$server · ${audio.toUpperCase()}',
            quality: _playlistQuality(playlist),
            headers: headers,
            audio: audio,
            subtitles: _megaplaySubtitles(data['tracks'], headers),
          ));
        } catch (_) {
          // One audio/server mirror failing must not suppress the others.
        }
      }
    }
    return out;
  }

  Future<List<UnifiedStreamOption>> _animePahe(
    SourceManifest source,
    _AnimeEpisodeRef ref,
    CancelToken? token,
  ) async {
    if (!Platform.isAndroid) {
      throw const FormatException(
        'AnimePahe requires the Android WebView challenge bridge in this build.',
      );
    }
    final base = source.engine.endpoint.replaceAll(RegExp(r'/+$'), '');
    final session = await _animePaheSession(base, ref, token);
    if (session == null) return const <UnifiedStreamOption>[];
    final episodeSession = await _animePaheEpisodeSession(base, session, ref.episode, token);
    if (episodeSession == null) return const <UnifiedStreamOption>[];

    final play = await _animePaheGetText(
      '$base/play/$session/$episodeSession',
      referer: '$base/',
      cancelToken: token,
    );
    final buttonTags = RegExp(
      r"""<button\b[^>]*data-src=["'][^"']+["'][^>]*>""",
      caseSensitive: false,
    ).allMatches(play).map((match) => match.group(0)!).toList(growable: false);
    final buttons = buttonTags.map((tag) {
      return <String, String>{
        'src': _attribute(tag, 'src'),
        'resolution': _attribute(tag, 'resolution'),
        'audio': _attribute(tag, 'audio'),
        'fansub': _decodeHtml(_attribute(tag, 'fansub')),
      };
    }).where((button) => button['src']?.startsWith('http') == true).toList()
      ..sort((a, b) =>
          (int.tryParse(b['resolution'] ?? '') ?? 0)
              .compareTo(int.tryParse(a['resolution'] ?? '') ?? 0));

    final futures = buttons.map((button) async {
      try {
        final kwik = button['src']!;
        final kwikUri = Uri.parse(kwik);
        final kwikHeaders = <String, String>{
          'Referer': '$base/',
          'User-Agent': _animePaheActiveUserAgent ?? _animePaheDefaultUserAgent,
        };
        final html = await _getText(
          kwik,
          headers: kwikHeaders,
          cancelToken: token,
        );
        final unpacked = _unpackPacker(html);
        final match = RegExp(
          r"""https?://[^"'\\\s]+\.m3u8[^"'\\\s]*""",
          caseSensitive: false,
        ).firstMatch(unpacked);
        final streamUrl = match?.group(0);
        if (streamUrl == null) return null;
        final audio = button['audio'] == 'eng' ? 'dub' : 'sub';
        final resolution = int.tryParse(button['resolution'] ?? '');
        final headers = <String, String>{
          'Referer': '${kwikUri.scheme}://${kwikUri.host}/',
          'User-Agent': _animePaheActiveUserAgent ?? _animePaheDefaultUserAgent,
        };
        return _stream(
          source: source,
          url: streamUrl,
          name: '${button['fansub']?.trim().isNotEmpty == true ? button['fansub'] : 'Kwik'} · ${audio.toUpperCase()}',
          quality: resolution == null ? null : '${resolution}p',
          headers: headers,
          audio: audio,
        );
      } catch (_) {
        return null;
      }
    }).toList(growable: false);
    final resolved = await Future.wait(futures);
    return resolved.whereType<UnifiedStreamOption>().toList(growable: false);
  }

  Future<String?> _animePaheSession(
    String base,
    _AnimeEpisodeRef ref,
    CancelToken? token,
  ) async {
    final cached = _animePaheSessionCache[ref.anilistId];
    if (cached != null) return cached;
    final linkPattern = RegExp(
      'anilist\\.co/anime/${ref.anilistId}\\b|myanimelist\\.net/anime/${ref.malId ?? 'none'}\\b',
      caseSensitive: false,
    );
    for (final title in ref.titles) {
      final response = await _animePaheGetJson(
        '$base/api?m=search&q=${Uri.encodeQueryComponent(title)}',
        referer: '$base/',
        cancelToken: token,
      );
      final data = response['data'];
      if (data is! List) continue;
      final sessions = data.whereType<Map>()
          .map((item) => item['session']?.toString() ?? '')
          .where((value) => value.isNotEmpty)
          .take(3);
      for (final session in sessions) {
        final html = await _animePaheGetText(
          '$base/anime/$session',
          referer: '$base/',
          cancelToken: token,
        );
        if (linkPattern.hasMatch(html)) {
          _animePaheSessionCache[ref.anilistId] = session;
          return session;
        }
      }
    }
    return null;
  }

  Future<String?> _animePaheEpisodeSession(
    String base,
    String session,
    int episode,
    CancelToken? token,
  ) async {
    final first = await _animePaheGetJson(
      '$base/api?m=release&id=$session&sort=episode_asc&page=1',
      referer: '$base/',
      cancelToken: token,
    );
    final firstData = first['data'];
    if (firstData is! List || firstData.isEmpty || firstData.first is! Map) return null;
    final firstNumber = double.tryParse(
      ((firstData.first as Map)['episode'] ?? '').toString(),
    )?.toInt();
    if (firstNumber == null) return null;
    final offset = (firstNumber - 1).clamp(0, 100000).toInt();
    final rawPerPage = int.tryParse('${first['per_page'] ?? ''}');
    final perPage = rawPerPage != null && rawPerPage > 0
        ? rawPerPage
        : firstData.length.clamp(1, 1000).toInt();
    final target = episode + offset;
    final pageNumber = ((target - firstNumber) ~/ perPage) + 1;
    final data = pageNumber <= 1
        ? firstData
        : (await _animePaheGetJson(
            '$base/api?m=release&id=$session&sort=episode_asc&page=$pageNumber',
            referer: '$base/',
            cancelToken: token,
          ))['data'];
    if (data is! List) return null;
    for (final item in data.whereType<Map>()) {
      final number = double.tryParse('${item['episode'] ?? ''}');
      if (number == target.toDouble()) return item['session']?.toString();
    }
    return null;
  }

  Future<Map<String, dynamic>> _animePaheGetJson(
    String url, {
    required String referer,
    CancelToken? cancelToken,
  }) async => _map(jsonDecode(await _animePaheGetText(
        url,
        referer: referer,
        cancelToken: cancelToken,
      )));

  Future<String> _animePaheGetText(
    String url, {
    required String referer,
    CancelToken? cancelToken,
    bool retried = false,
  }) async {
    _validateUrl(url);
    final headers = <String, String>{
      'User-Agent': _animePaheActiveUserAgent ?? _animePaheDefaultUserAgent,
      'Referer': referer,
      'Accept': '*/*',
      if (_animePaheCookie?.isNotEmpty == true) 'Cookie': _animePaheCookie!,
    };
    final response = await _dio.get<String>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.plain,
        headers: headers,
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 20),
        validateStatus: (status) => status != null && status >= 200 && status < 600,
      ),
    );
    final body = response.data ?? '';
    final status = response.statusCode ?? 0;
    final lowerBody = body.toLowerCase();
    final challenge = status == 403 || status == 503 ||
        lowerBody.contains('just a moment') || lowerBody.contains('cf-chl-');
    if (challenge && !retried) {
      await _ensureAnimePaheClearance(url, cancelToken, forceRefresh: true);
      return _animePaheGetText(
        url,
        referer: referer,
        cancelToken: cancelToken,
        retried: true,
      );
    }
    if (status < 200 || status >= 400) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'AnimePahe returned HTTP $status after Cloudflare clearance.',
        type: DioExceptionType.badResponse,
      );
    }
    if (challenge) {
      throw const FormatException(
        'AnimePahe challenge was not cleared. This may require an interactive Turnstile check.',
      );
    }
    return body;
  }

  Future<void> _ensureAnimePaheClearance(
    String url,
    CancelToken? token, {
    bool forceRefresh = false,
  }) async {
    final expiry = _animePaheCookieExpiresAt;
    if (!forceRefresh &&
        _animePaheCookie?.contains('cf_clearance=') == true &&
        expiry != null && DateTime.now().isBefore(expiry)) {
      return;
    }
    if (!Platform.isAndroid) {
      throw const FormatException('AnimePahe Cloudflare clearance requires Android WebView.');
    }
    if (token?.isCancelled == true) {
      throw token!.cancelError ?? DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.cancel,
        message: 'AnimePahe clearance request was cancelled.',
      );
    }
    final uri = Uri.parse(url);
    final origin = '${uri.scheme}://${uri.host}/';
    final result = await _webEmbedChannel.invokeMethod<Map<dynamic, dynamic>>(
      'resolveCloudflare',
      <String, dynamic>{'url': origin, 'timeoutMs': 18000},
    );
    final cookies = result?['cookies']?.toString() ?? '';
    final userAgent = result?['userAgent']?.toString() ?? '';
    if (!cookies.contains('cf_clearance=') || userAgent.isEmpty) {
      throw const FormatException(
        'AnimePahe Cloudflare clearance was not obtained. The site may require a user-interactive challenge.',
      );
    }
    _animePaheCookie = cookies;
    _animePaheActiveUserAgent = userAgent;
    _animePaheCookieExpiresAt = DateTime.now().add(const Duration(minutes: 10));
  }

  String _unpackPacker(String input) {
    final match = RegExp(
      r"""\}\('(.*)',\s*(\d+),\s*(\d+),\s*'(.*?)'\.split\('\|'\)""",
      dotAll: true,
    ).firstMatch(input);
    if (match == null) return input;
    final payload = match.group(1)!;
    final radix = int.parse(match.group(2)!);
    final count = int.parse(match.group(3)!);
    final words = match.group(4)!.split('|');
    if (radix < 2 || radix > 62 || count <= 0 || count > 100000) return input;
    String encode(int value) {
      final prefix = value < radix ? '' : encode(value ~/ radix);
      final digit = value % radix;
      final char = digit > 35
          ? String.fromCharCode(digit + 29)
          : digit.toRadixString(36);
      return '$prefix$char';
    }
    final dictionary = <String, String>{};
    for (var index = 0; index < count; index++) {
      final key = encode(index);
      dictionary[key] = index < words.length && words[index].isNotEmpty
          ? words[index]
          : key;
    }
    final body = payload.replaceAll(r"\'", "'");
    return body.replaceAllMapped(RegExp(r'\b\w+\b'), (item) {
      return dictionary[item.group(0)] ?? item.group(0)!;
    });
  }

  String _decodeHtml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');

  Future<List<UnifiedStreamOption>> _fourAnimo(
    SourceManifest source,
    _AnimeEpisodeRef ref,
    CancelToken? token,
  ) async {
    final base = source.engine.endpoint.replaceAll(RegExp(r'/+$'), '');
    const siteReferer = 'https://4animo.xyz/';
    final out = <UnifiedStreamOption>[];
    for (final audio in <String>['sub', 'dub']) {
      try {
        final embed = '$base/embed/ani/${ref.anilistId}/${ref.episode}/$audio?k=1';
        final page = await _getText(embed, headers: <String, String>{'Referer': siteReferer}, cancelToken: token);
        final path = RegExp(r"sourcesUrl\s*=\s*'([^']+)'", caseSensitive: false).firstMatch(page)?.group(1);
        if (path == null) continue;
        final sourcesUrl = _absolute(path, base);
        final data = await _getJson(sourcesUrl, headers: <String, String>{'Referer': embed}, cancelToken: token);
        final sources = data['sources'];
        final file = sources is List && sources.isNotEmpty && sources.first is Map
            ? (sources.first as Map)['file']?.toString() ?? ''
            : '';
        if (file.isEmpty) continue;
        final url = _absolute(file, base);
        final headers = <String, String>{'Referer': '$base/', 'Origin': base, 'User-Agent': _userAgent};
        final playlist = await _getText(url, headers: headers, cancelToken: token);
        if (!playlist.trimLeft().startsWith('#EXTM3U')) continue;
        final server = (data['server'] ?? 'HD-1').toString();
        final stream = _stream(
          source: source,
          url: url,
          name: '$server · ${audio.toUpperCase()}',
          quality: _playlistQuality(playlist),
          headers: headers,
          audio: audio,
          subtitles: _megaplaySubtitles(data['tracks'], headers, base: base),
        );
        final metadata = <String, dynamic>{};
        final intro = _segment(data['intro']);
        final outro = _segment(data['outro']);
        if (intro != null) metadata['intro'] = intro;
        if (outro != null) metadata['outro'] = outro;
        out.add(UnifiedStreamOption(
          id: stream.id,
          providerId: stream.providerId,
          providerName: stream.providerName,
          url: stream.url,
          label: stream.label,
          quality: stream.quality,
          container: stream.container,
          headers: stream.headers,
          audioKind: stream.audioKind,
          audioLanguage: stream.audioLanguage,
          subtitles: stream.subtitles,
          metadata: metadata,
        ));
      } catch (_) {}
    }
    return out;
  }

  Future<List<UnifiedStreamOption>> _animeGg(
    SourceManifest source,
    MediaIdentity media,
    _AnimeEpisodeRef ref,
    CancelToken? token,
  ) async {
    final base = source.engine.endpoint.replaceAll(RegExp(r'/+$'), '');
    final headers = <String, String>{'Referer': '$base/', 'Origin': base, 'User-Agent': _userAgent};
    String? slug;
    for (final title in ref.titles) {
      final html = await _getText(
        '$base/search/?q=${Uri.encodeQueryComponent(title)}',
        headers: headers,
        cancelToken: token,
      );
      final candidates = RegExp(r'href="/series/([a-z0-9-]+)"', caseSensitive: false)
          .allMatches(html)
          .map((match) => match.group(1)!)
          .toSet();
      final wanted = _slug(title);
      slug = candidates.firstWhereOrNull((value) => value == wanted) ?? candidates.firstOrNull;
      if (slug != null) break;
    }
    if (slug == null) return const <UnifiedStreamOption>[];
    final episodeUrl = '$base/$slug-episode-${ref.episode}';
    final page = await _getText(episodeUrl, headers: <String, String>{...headers, 'Referer': '$base/series/$slug'}, cancelToken: token);
    final tabs = RegExp(r'''<a\s+[^>]*data-id=["'](\d+)["'][^>]*data-version=["'](\w+)["'][^>]*>''', caseSensitive: false)
        .allMatches(page)
        .map((match) => (match.group(1)!, match.group(2)!.toLowerCase()))
        .toSet();
    final out = <UnifiedStreamOption>[];
    for (final (embedId, version) in tabs) {
      if (version != 'subbed' && version != 'dubbed') continue;
      final embed = '$base/embed/$embedId';
      final html = await _getText(embed, headers: <String, String>{...headers, 'Referer': episodeUrl}, cancelToken: token);
      final sources = RegExp(r'''file:\s*["'](/play/[^"']+)["']\s*,\s*label:\s*["'](\d+)p["']''')
          .allMatches(html)
          .toList()
        ..sort((a, b) => int.parse(b.group(2)!).compareTo(int.parse(a.group(2)!)));
      for (final match in sources) {
        final height = match.group(2)!;
        final url = '$base${match.group(1)!}';
        out.add(_stream(
          source: source,
          url: url,
          name: 'AnimeGG ${height}p · ${version == 'dubbed' ? 'DUB' : 'SUB'}',
          quality: '${height}p',
          headers: <String, String>{...headers, 'Referer': embed},
          audio: version == 'dubbed' ? 'dub' : 'sub',
          container: StreamContainer.mp4,
        ));
      }
    }
    return out;
  }

  Future<List<UnifiedStreamOption>> _anikoto(
    SourceManifest source,
    _AnimeEpisodeRef ref,
    CancelToken? token,
  ) async {
    final base = source.engine.endpoint.replaceAll(RegExp(r'/+$'), '');
    final ajaxHeaders = <String, String>{
      'Referer': '$base/',
      'X-Requested-With': 'XMLHttpRequest',
      'User-Agent': _userAgent,
    };
    for (final title in ref.titles) {
      final html = await _getText('$base/filter?keyword=${Uri.encodeQueryComponent(title)}', headers: ajaxHeaders, cancelToken: token);
      final candidates = RegExp(r'<a\s+class="name d-title"\s+href="([^"]+)"', caseSensitive: false)
          .allMatches(html)
          .map((match) => match.group(1)!)
          .take(5);
      for (final candidate in candidates) {
        try {
          final url = _absolute(candidate, base);
          final showPage = await _getText(url, headers: ajaxHeaders, cancelToken: token);
          final showId = RegExp(r'id="watch-main"[^>]*data-id="(\d+)"', caseSensitive: false).firstMatch(showPage)?.group(1);
          if (showId == null) continue;
          final response = await _getJson('$base/ajax/episode/list/$showId', headers: ajaxHeaders, cancelToken: token);
          final episodeHtml = response['result']?.toString() ?? '';
          final episodeTags = RegExp(r'<a\s+[^>]*data-num="[^"]*"[^>]*>', caseSensitive: false)
              .allMatches(episodeHtml)
              .map((match) => match.group(0)!)
              .toList(growable: false);
          final firstEpisodeMal = episodeTags.isEmpty ? '' : _attribute(episodeTags.first, 'mal');
          // OpenStream confirms Anikoto's search result against the MAL ID on
          // its first episode. This prevents same-title remakes from matching.
          if (ref.malId != null && firstEpisodeMal != ref.malId.toString()) {
            continue;
          }
          final episodeTag = episodeTags.firstWhereOrNull(
            (tag) => double.tryParse(_attribute(tag, 'num')) == ref.episode.toDouble(),
          );
          if (episodeTag != null) {
            final ids = _attribute(episodeTag, 'ids');
            if (ids.isNotEmpty) return _anikotoServers(source, base, ids, ajaxHeaders, token);
          }
        } catch (_) {}
      }
    }
    return const <UnifiedStreamOption>[];
  }

  Future<List<UnifiedStreamOption>> _anikotoServers(
    SourceManifest source,
    String base,
    String ids,
    Map<String, String> headers,
    CancelToken? token,
  ) async {
    final serverList = await _getJson('$base/ajax/server/list?servers=${Uri.encodeQueryComponent(ids)}', headers: headers, cancelToken: token);
    final html = serverList['result']?.toString() ?? '';
    final out = <UnifiedStreamOption>[];
    for (final audio in <String>['sub', 'dub']) {
      final block = RegExp('data-type="$audio">(.*?)</ul>', dotAll: true)
          .firstMatch(html)
          ?.group(1) ?? '';
      final links = RegExp(r'data-link-id="([^"]+)"[^>]*>([^<]+)<')
          .allMatches(block)
          .map((match) => (match.group(1)!, match.group(2)!.trim()));
      for (final (linkId, label) in links) {
        try {
          final result = await _getJson('$base/ajax/server?get=${Uri.encodeQueryComponent(linkId)}', headers: headers, cancelToken: token);
          final url = _map(result['result'])['url']?.toString() ?? '';
          if (url.isEmpty) continue;
          if (url.contains('megaplay')) {
            final streams = await _resolveMegaPlay(source, url, '$base/', audio, label, token);
            out.addAll(streams);
          } else {
            // Reuse the same hoster extractor registry used by Zangetsu JS
            // providers. If no bundled extractor recognises the host, fall
            // back to the OpenStream-style WebView request sniffer.
            try {
              final raw = await _quickJsRuntime.extractVideo(
                url,
                options: <String, dynamic>{'headers': <String, String>{...headers, 'Referer': '$base/'}},
                timeout: const Duration(seconds: 18),
                cancelToken: token,
              );
              final extracted = mapQuickJsVideoSources(source, raw, idPrefix: 'anikoto-hoster');
              if (extracted.isNotEmpty) {
                out.addAll(extracted.map((stream) => UnifiedStreamOption(
                  id: stream.id,
                  providerId: stream.providerId,
                  providerName: stream.providerName,
                  url: stream.url,
                  label: '$label · ${audio.toUpperCase()}${stream.label == null ? '' : ' · ${stream.label}'}',
                  quality: stream.quality,
                  container: stream.container,
                  headers: stream.headers,
                  audioKind: audio == 'dub' ? StreamAudioKind.dub : StreamAudioKind.sub,
                  audioLanguage: audio == 'dub' ? 'English' : 'Japanese',
                  subtitles: stream.subtitles,
                )));
                continue;
              }
            } catch (_) {
              // Fall through to browser capture for unrecognised/changed hosters.
            }
            try {
              final captured = await _webEmbedChannel.invokeMethod<List<dynamic>>(
                'resolveUrl',
                <String, dynamic>{'url': url, 'referer': '$base/', 'timeoutMs': 16000},
              );
              for (final item in captured ?? const <dynamic>[]) {
                if (item is! Map) continue;
                final data = Map<String, dynamic>.from(item);
                final streamUrl = data['url']?.toString() ?? '';
                if (streamUrl.isEmpty) continue;
                out.add(_stream(
                  source: source,
                  url: streamUrl,
                  name: '$label · ${audio.toUpperCase()}',
                  quality: data['quality']?.toString(),
                  headers: _stringMap(data['headers']),
                  audio: audio,
                ));
              }
            } catch (_) {}
          }
        } catch (_) {}
      }
    }
    return out;
  }

  Future<List<UnifiedStreamOption>> _resolveMegaPlay(
    SourceManifest source,
    String embed,
    String referer,
    String audio,
    String label,
    CancelToken? token,
  ) async {
    final page = await _getText(embed, headers: <String, String>{'Referer': referer}, cancelToken: token);
    final id = RegExp(r'data-id="(\d+)"').firstMatch(page)?.group(1);
    if (id == null) return const <UnifiedStreamOption>[];
    final uri = Uri.parse(embed);
    final origin = '${uri.scheme}://${uri.host}';
    final data = await _getJson(
      '$origin/stream/getSourcesNew?id=$id${uri.queryParameters['s'] == null ? '' : '&s=${uri.queryParameters['s']}'}',
      headers: <String, String>{'Referer': embed, 'X-Requested-With': 'XMLHttpRequest'},
      cancelToken: token,
    );
    final enc = data['enc']?.toString();
    if (enc == null) return const <UnifiedStreamOption>[];
    final file = _decryptMegaplay(enc)['file']?.toString() ?? '';
    if (file.isEmpty) return const <UnifiedStreamOption>[];
    final headers = <String, String>{'Referer': '$origin/', 'User-Agent': _userAgent};
    final playlist = await _getText(file, headers: headers, cancelToken: token);
    if (!playlist.trimLeft().startsWith('#EXTM3U')) return const <UnifiedStreamOption>[];
    return <UnifiedStreamOption>[_stream(
      source: source,
      url: file,
      name: '$label · ${audio.toUpperCase()}',
      quality: _playlistQuality(playlist),
      headers: headers,
      audio: audio,
      subtitles: _megaplaySubtitles(data['tracks'], headers),
    )];
  }

  Map<String, dynamic> _decryptMegaplay(String encrypted) {
    final normalized = encrypted.trim().replaceAll('-', '+').replaceAll('_', '/');
    final padded = normalized.padRight((normalized.length + 3) ~/ 4 * 4, '=');
    final key = Uint8List(32)..setRange(0, _megaplayKey.length, utf8.encode(_megaplayKey));
    final iv = Uint8List(16)..setRange(0, _megaplayIv.length, utf8.encode(_megaplayIv));
    final plain = aesCbcDecryptUtf8(
      key: key,
      iv: iv,
      data: Uint8List.fromList(base64Decode(padded)),
    );
    return _map(jsonDecode(plain));
  }

  List<UnifiedSubtitleTrack> _megaplaySubtitles(
    dynamic raw,
    Map<String, String> headers, {
    String? base,
  }) {
    if (raw is! List) return const <UnifiedSubtitleTrack>[];
    return raw.whereType<Map>().where((track) {
      final kind = (track['kind'] ?? '').toString().toLowerCase();
      return kind.isEmpty || kind == 'captions' || kind == 'subtitles';
    }).map((track) {
      final label = (track['label'] ?? 'Unknown').toString();
      final rawUrl = (track['file'] ?? '').toString();
      final url = base == null ? rawUrl : _absolute(rawUrl, base);
      return UnifiedSubtitleTrack(
        url: url,
        language: _languageCode(label) ?? label,
        label: label,
        format: url.toLowerCase().endsWith('.vtt') ? 'vtt' : null,
        headers: headers,
      );
    }).where((track) => track.url.startsWith('http')).toList(growable: false);
  }

  Map<String, double>? _segment(dynamic raw) {
    if (raw is! Map) return null;
    final start = raw['start'] is num
        ? (raw['start'] as num).toDouble()
        : double.tryParse('${raw['start']}');
    final end = raw['end'] is num
        ? (raw['end'] as num).toDouble()
        : double.tryParse('${raw['end']}');
    if (start == null || end == null || end <= start) return null;
    return <String, double>{'start': start, 'end': end};
  }

  String? _languageCode(String label) {
    final normalized = label.split('(').first.trim().toLowerCase();
    const codes = <String, String>{
      'english': 'en', 'japanese': 'ja', 'arabic': 'ar', 'spanish': 'es',
      'french': 'fr', 'german': 'de', 'portuguese': 'pt', 'italian': 'it',
      'russian': 'ru', 'korean': 'ko', 'chinese': 'zh', 'hindi': 'hi',
      'turkish': 'tr', 'indonesian': 'id', 'thai': 'th', 'vietnamese': 'vi',
    };
    return codes[normalized];
  }

  UnifiedStreamOption _stream({
    required SourceManifest source,
    required String url,
    required String name,
    String? quality,
    required Map<String, String> headers,
    required String audio,
    List<UnifiedSubtitleTrack> subtitles = const <UnifiedSubtitleTrack>[],
    StreamContainer container = StreamContainer.hls,
  }) => UnifiedStreamOption(
        id: '${source.id}-${url.hashCode}-${audio}',
        providerId: source.id,
        providerName: source.name,
        url: url,
        label: name,
        quality: quality,
        container: container,
        headers: headers,
        audioKind: audio == 'dub' ? StreamAudioKind.dub : StreamAudioKind.sub,
        audioLanguage: audio == 'dub' ? 'English' : 'Japanese',
        subtitles: subtitles,
      );

  Future<String> _getText(
    String url, {
    Map<String, String> headers = const <String, String>{},
    CancelToken? cancelToken,
  }) async {
    _validateUrl(url);
    final response = await _dio.get<String>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.plain,
        headers: <String, String>{'User-Agent': _userAgent, ...headers},
        receiveTimeout: const Duration(seconds: 18),
        sendTimeout: const Duration(seconds: 18),
        validateStatus: (status) => status != null && status >= 200 && status < 400,
      ),
    );
    return response.data ?? '';
  }

  Future<Map<String, dynamic>> _getJson(
    String url, {
    Map<String, String> headers = const <String, String>{},
    CancelToken? cancelToken,
  }) async {
    final raw = await _getText(url, headers: headers, cancelToken: cancelToken);
    return _map(jsonDecode(raw));
  }

  Options get _jsonOptions => Options(
        responseType: ResponseType.json,
        headers: const <String, String>{'User-Agent': _userAgent, 'Accept': 'application/json'},
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 15),
        validateStatus: (status) => status != null && status >= 200 && status < 400,
      );

  Map<String, dynamic> _map(dynamic value) => value is Map
      ? Map<String, dynamic>.from(value)
      : <String, dynamic>{};

  int? _int(dynamic value) => value is num ? value.toInt() : int.tryParse('$value');

  String _absolute(String value, String base) {
    final uri = Uri.tryParse(value);
    return uri != null && uri.hasScheme ? value : Uri.parse(base).resolve(value).toString();
  }

  String _attribute(String tag, String name) =>
      RegExp("data-$name=[\"']([^\"']*)[\"']", caseSensitive: false)
              .firstMatch(tag)
              ?.group(1) ??
          '';

  String _slug(String title) => title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');

  String? _playlistQuality(String playlist) {
    final heights = RegExp(r'RESOLUTION=\d+x(\d+)')
        .allMatches(playlist)
        .map((match) => int.tryParse(match.group(1)!))
        .whereType<int>()
        .toList()
      ..sort((a, b) => b.compareTo(a));
    return heights.isEmpty ? null : '${heights.first}p';
  }

  Map<String, String> _stringMap(dynamic value) {
    if (value is! Map) return const <String, String>{};
    return <String, String>{
      for (final entry in value.entries)
        if (entry.value != null) entry.key.toString(): entry.value.toString(),
    };
  }

  void _validateUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('Anime provider URL is invalid.');
    }
  }
}

extension _IterableFirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
  T? firstWhereOrNull(bool Function(T element) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}
