import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../models/external_subtitles.dart';
import '../video_providers/scraper_api.dart';
import '../video_providers/unified/media_identity.dart';
import '../video_providers/unified/media_identity_resolver.dart';
import 'subtitle_file_normalizer.dart';

/// Aggregates the subtitle sources used by OpenStream (OpenSubtitles and
/// SubSource) while retaining CineStream's existing Scraper API as an
/// additional provider/fallback.
///
/// OpenSubtitles uses its current API v1 when an application key is configured
/// and keeps the older public REST endpoint as a best-effort compatibility
/// fallback. SubSource uses its undocumented `/v1` flow: IMDb search -> title
/// link -> language/episode list -> detail endpoint -> short-lived download
/// token -> ZIP file. SubDL and an optional server-side ArabicSubs proxy are
/// independent sources. Every provider is isolated so one outage never hides
/// the results returned by the other providers.
class ExternalSubtitleService {
  ExternalSubtitleService(
    this.scraperApiUrl, {
    http.Client? client,
    MediaIdentityResolver? identityResolver,
    String? openSubtitlesApiKey,
    String? subDlApiKey,
    String? arabicSubsProxyUrl,
  })  : _client = client ?? _sharedClient,
        _identityResolver = identityResolver ?? _sharedIdentityResolver,
        _openSubtitlesApiKey = (openSubtitlesApiKey ??
                dotenv.env['OPENSUBTITLES_API_KEY'] ?? '')
            .trim(),
        _subDlApiKey = (subDlApiKey ?? dotenv.env['SUBDL_API_KEY'] ?? '').trim(),
        _arabicSubsProxyUrl = (arabicSubsProxyUrl ??
                dotenv.env['ARABICSUBS_PROXY_URL'] ?? '')
            .trim()
            .replaceAll(RegExp(r'/+$'), '');

  final String scraperApiUrl;
  final http.Client _client;
  final MediaIdentityResolver _identityResolver;
  final String _openSubtitlesApiKey;
  final String _subDlApiKey;
  final String _arabicSubsProxyUrl;

  static final http.Client _sharedClient = http.Client();
  static final MediaIdentityResolver _sharedIdentityResolver =
      MediaIdentityResolver();

  static const String _openSubtitlesBase = 'https://rest.opensubtitles.org';
  static const String _openSubtitlesV1Base = 'https://api.opensubtitles.com/api/v1';
  static const String _openSubtitlesUserAgent = 'TemporaryUserAgent';
  static const String _subSourceBase = 'https://api.subsource.net/v1';
  static const String _subDlBase = 'https://api.subdl.com/api/v1/subtitles';
  static const String _subDlDownloadBase = 'https://dl.subdl.com';
  static const Duration _searchTimeout = Duration(seconds: 18);
  static const Duration _downloadTimeout = Duration(seconds: 25);
  static const int _maxSubtitleDownloadBytes = 24 * 1024 * 1024;

  /// Search movie subtitles by TMDB id. The IMDb id is resolved through the
  /// same TMDB `external_ids` mapping used by OpenStream's IdMappingService.
  Future<List<ExternalSubtitle>> fetchMovieSubtitles(
    int tmdbId, {
    String? title,
    int? year,
    String? preferredLanguageCode,
  }) => _search(
        tmdbId: tmdbId,
        title: title,
        year: year,
        isMovie: true,
        preferredLanguageCode: preferredLanguageCode,
      );

  /// Search subtitles for one exact TV episode (not the whole season).
  Future<List<ExternalSubtitle>> fetchTVSubtitles(
    int tmdbId,
    int seasonNumber,
    int episodeNumber, {
    String? title,
    int? year,
    String? preferredLanguageCode,
  }) => _search(
        tmdbId: tmdbId,
        title: title,
        year: year,
        season: seasonNumber,
        episode: episodeNumber,
        isMovie: false,
        preferredLanguageCode: preferredLanguageCode,
      );

  Future<List<ExternalSubtitle>> _search({
    required int tmdbId,
    required bool isMovie,
    String? title,
    int? year,
    int? season,
    int? episode,
    String? preferredLanguageCode,
  }) async {
    if (tmdbId <= 0) return const <ExternalSubtitle>[];

    final identity = MediaIdentity(
      type: isMovie ? UnifiedMediaType.movie : UnifiedMediaType.series,
      tmdbId: tmdbId,
      title: title?.trim().isNotEmpty == true ? title!.trim() : 'TMDB $tmdbId',
      year: year,
      seasonNumber: season,
      episodeNumber: episode,
    );

    // Start the existing scraper request and the IMDb mapping concurrently.
    // A failed mapping only disables the two IMDb-based sources; the current
    // CineStream scraper remains available by TMDB id.
    final scraperFuture = _searchScraper(
      tmdbId: tmdbId,
      season: season,
      episode: episode,
    );
    final enrichedFuture = _identityResolver
        .enrich(identity)
        .timeout(const Duration(seconds: 9), onTimeout: () => identity)
        .catchError((Object _) => identity);

    final enriched = await enrichedFuture;
    final imdbId = enriched.imdbId;
    final providerFutures = <Future<List<ExternalSubtitle>>>[
      // The supported OpenSubtitles v1 API is used whenever the app key is
      // configured. The legacy endpoint remains a best-effort compatibility
      // fallback for existing installations that have not supplied a key.
      if (_openSubtitlesApiKey.isNotEmpty)
        _searchOpenSubtitlesV1(
          tmdbId: tmdbId,
          isMovie: isMovie,
          season: season,
          episode: episode,
          preferredLanguageCode: preferredLanguageCode,
        ).catchError((Object error) {
          debugPrint('[Subtitle][OpenSubtitlesV1] Search failed: $error');
          return const <ExternalSubtitle>[];
        })
      else if (imdbId != null)
        _searchOpenSubtitles(
          imdbId: imdbId,
          isMovie: isMovie,
          season: season,
          episode: episode,
          preferredLanguageCode: preferredLanguageCode,
        ).catchError((Object error) {
          debugPrint('[Subtitle][OpenSubtitlesLegacy] Search failed: $error');
          return const <ExternalSubtitle>[];
        }),
      if (imdbId != null)
        _searchSubSource(
          imdbId: imdbId,
          isMovie: isMovie,
          season: season,
          episode: episode,
          preferredLanguageCode: preferredLanguageCode,
        ).catchError((Object error) {
          debugPrint('[Subtitle][SubSource] Search failed: $error');
          return const <ExternalSubtitle>[];
        }),
      if (_subDlApiKey.isNotEmpty)
        _searchSubDl(
          tmdbId: tmdbId,
          title: title,
          year: year,
          isMovie: isMovie,
          season: season,
          episode: episode,
        ).catchError((Object error) {
          debugPrint('[Subtitle][SubDL] Search failed: $error');
          return const <ExternalSubtitle>[];
        }),
      if (_arabicSubsProxyUrl.isNotEmpty)
        _searchArabicSubsProxy(
          tmdbId: tmdbId,
          title: title,
          year: year,
          isMovie: isMovie,
          season: season,
          episode: episode,
        ).catchError((Object error) {
          debugPrint('[Subtitle][ArabicSubs] Search failed: $error');
          return const <ExternalSubtitle>[];
        }),
      scraperFuture.catchError((Object error) {
        debugPrint('[Subtitle][ScraperAPI] Search failed: $error');
        return const <ExternalSubtitle>[];
      }),
    ];

    final results = await Future.wait(providerFutures).timeout(
      const Duration(seconds: 48),
      onTimeout: () => const <List<ExternalSubtitle>>[],
    );
    return _mergeAndSort(results.expand((result) => result), preferredLanguageCode);
  }

  Future<List<ExternalSubtitle>> _searchScraper({
    required int tmdbId,
    int? season,
    int? episode,
  }) async {
    if (scraperApiUrl.trim().isEmpty) return const <ExternalSubtitle>[];
    final results = await ScraperApi(scraperApiUrl).searchSubtitles(
      tmdbId: tmdbId,
      season: season,
      episode: episode,
    );
    return results
        .map((subtitle) => ExternalSubtitle(
              id: subtitle.id,
              url: subtitle.url,
              flagUrl: subtitle.flagUrl,
              format: subtitle.format,
              encoding: subtitle.encoding,
              display: subtitle.display,
              language: subtitle.language,
              media: subtitle.media,
              isHearingImpaired: subtitle.isHearingImpaired,
              release: subtitle.release,
              source: subtitle.source,
            ))
        .toList(growable: false);
  }

  Future<List<ExternalSubtitle>> _searchOpenSubtitlesV1({
    required int tmdbId,
    required bool isMovie,
    required String? preferredLanguageCode,
    int? season,
    int? episode,
  }) async {
    final languages = <String>{
      _normaliseLanguageCode(preferredLanguageCode),
      'en',
    }..remove('');
    final params = <String, String>{
      'languages': (languages.toList()..sort()).join(','),
      'type': isMovie ? 'movie' : 'episode',
      if (isMovie) 'tmdb_id': '$tmdbId',
      if (!isMovie) 'parent_tmdb_id': '$tmdbId',
      if (!isMovie && season != null) 'season_number': '$season',
      if (!isMovie && episode != null) 'episode_number': '$episode',
      'order_by': 'download_count',
      'order_direction': 'desc',
    };
    // Query parameters are encoded by Uri; the OpenSubtitles API requires a
    // stable lower-case app User-Agent and an application Api-Key.
    final uri = Uri.parse('$_openSubtitlesV1Base/subtitles')
        .replace(queryParameters: params);
    final response = await _client.get(uri, headers: <String, String>{
      'Api-Key': _openSubtitlesApiKey,
      'User-Agent': 'CineStream PRO v1.0',
      'Accept': 'application/json',
    }).timeout(_searchTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException(
        'OpenSubtitles v1 returned HTTP ${response.statusCode}.',
        uri,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['data'] is! List) {
      return const <ExternalSubtitle>[];
    }

    final results = <ExternalSubtitle>[];
    for (final item in (decoded['data'] as List).whereType<Map>()) {
      final attributes = item['attributes'];
      if (attributes is! Map) continue;
      final language = _normaliseLanguageCode(
        attributes['language']?.toString(),
      );
      final files = attributes['files'];
      if (files is! List) continue;
      for (final file in files.whereType<Map>()) {
        final fileId = int.tryParse(file['file_id']?.toString() ?? '');
        if (fileId == null || fileId <= 0) continue;
        final fileName = file['file_name']?.toString() ?? '';
        final extension = fileName.split('.').last.toLowerCase();
        results.add(ExternalSubtitle(
          id: 'opensubtitles_v1_$fileId',
          url: 'opensubtitles-v1://file/$fileId',
          flagUrl: '',
          format: const <String>{'srt', 'vtt', 'ass', 'ssa'}.contains(extension)
              ? extension
              : 'srt',
          encoding: 'UTF-8/auto',
          display: _languageName(language),
          language: language,
          media: isMovie ? 'movie' : 'tv',
          isHearingImpaired: attributes['hearing_impaired'] == true,
          release: attributes['release']?.toString() ?? fileName,
          source: 'OpenSubtitles',
        ));
      }
    }
    return results;
  }

  Future<List<ExternalSubtitle>> _searchSubDl({
    required int tmdbId,
    required String? title,
    required int? year,
    required bool isMovie,
    int? season,
    int? episode,
  }) async {
    final uri = Uri.parse(_subDlBase).replace(queryParameters: <String, String>{
      'api_key': _subDlApiKey,
      'client': 'other',
      'tmdb_id': '$tmdbId',
      'type': isMovie ? 'movie' : 'tv',
      'languages': 'AR,EN',
      'subs_per_page': '30',
      if (!isMovie && season != null) 'season_number': '$season',
      if (!isMovie && episode != null) 'episode_number': '$episode',
      if (year != null) 'year': '$year',
      if (title?.trim().isNotEmpty == true) 'film_name': title!.trim(),
    });
    final response = await _client.get(uri, headers: const <String, String>{
      'Accept': 'application/json',
    }).timeout(_searchTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException('SubDL returned HTTP ${response.statusCode}.', uri);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['status'] == false) {
      return const <ExternalSubtitle>[];
    }
    final rows = decoded['subtitles'];
    if (rows is! List) return const <ExternalSubtitle>[];
    final results = <ExternalSubtitle>[];
    for (final row in rows.whereType<Map>()) {
      final language = _normaliseLanguageCode(
        row['language']?.toString() ?? row['lang']?.toString() ??
            row['language_code']?.toString(),
      );
      if (language != 'ar' && language != 'en') continue;
      final rawUrl = row['url']?.toString().trim() ?? '';
      if (rawUrl.isEmpty) continue;
      final uri = rawUrl.startsWith('http')
          ? rawUrl
          : '$_subDlDownloadBase${rawUrl.startsWith('/') ? '' : '/'}$rawUrl';
      final release = row['release_name']?.toString() ??
          row['name']?.toString() ?? '';
      final id = row['n_id']?.toString() ?? row['id']?.toString() ?? rawUrl;
      results.add(ExternalSubtitle(
        id: 'subdl_${id}_$language',
        url: uri,
        flagUrl: '',
        format: row['format']?.toString() ?? 'zip',
        encoding: 'zip/auto',
        display: _languageName(language),
        language: language,
        media: isMovie ? 'movie' : 'tv',
        isHearingImpaired: row['hi'] == true || row['hi']?.toString() == '1',
        release: release,
        source: 'SubDL',
      ));
    }
    return results;
  }

  /// ArabicSubs keys must stay server-side. This optional adapter talks only
  /// to a user's own proxy, which forwards the documented ArabicSubs API and
  /// keeps its Authorization bearer key out of the APK.
  Future<List<ExternalSubtitle>> _searchArabicSubsProxy({
    required int tmdbId,
    required String? title,
    required int? year,
    required bool isMovie,
    int? season,
    int? episode,
  }) async {
    if (title?.trim().isNotEmpty != true) return const <ExternalSubtitle>[];
    final searchUri = Uri.parse('$_arabicSubsProxyUrl/search').replace(
      queryParameters: <String, String>{'q': title!.trim(), 'limit': '25'},
    );
    final searchResponse = await _client.get(searchUri, headers: const {
      'Accept': 'application/json',
    }).timeout(_searchTimeout);
    if (searchResponse.statusCode < 200 || searchResponse.statusCode >= 300) {
      throw http.ClientException('ArabicSubs proxy search failed.', searchUri);
    }
    final searchBody = jsonDecode(searchResponse.body);
    if (searchBody is! Map || searchBody['items'] is! List) {
      return const <ExternalSubtitle>[];
    }
    final titles = (searchBody['items'] as List).whereType<Map>().toList();
    Map? match;
    for (final candidate in titles) {
      final providerId = candidate['providerId']?.toString();
      final candidateType = candidate['type']?.toString().toLowerCase();
      final typeMatches = isMovie
          ? candidateType == 'movie'
          : candidateType == 'series' || candidateType == 'tv';
      if (providerId == '$tmdbId' && typeMatches) {
        match = candidate;
        break;
      }
    }
    match ??= titles.cast<Map?>().firstWhere(
      (candidate) {
        if (candidate == null) return false;
        final candidateType = candidate['type']?.toString().toLowerCase();
        final typeMatches = isMovie
            ? candidateType == 'movie'
            : candidateType == 'series' || candidateType == 'tv';
        final candidateYear = int.tryParse(candidate['year']?.toString() ?? '');
        return typeMatches && (year == null || candidateYear == null || candidateYear == year);
      },
      orElse: () => null,
    );
    final titleId = match?['id']?.toString();
    if (titleId == null || titleId.isEmpty) return const <ExternalSubtitle>[];

    final subtitlesUri = Uri.parse(
      '$_arabicSubsProxyUrl/titles/${Uri.encodeComponent(titleId)}/subtitles',
    ).replace(queryParameters: <String, String>{
      if (!isMovie && season != null) 'season': '$season',
      if (!isMovie && episode != null) 'episode': '$episode',
      'limit': '100',
    });
    final subtitlesResponse = await _client.get(subtitlesUri, headers: const {
      'Accept': 'application/json',
    }).timeout(_searchTimeout);
    if (subtitlesResponse.statusCode < 200 || subtitlesResponse.statusCode >= 300) {
      throw http.ClientException('ArabicSubs subtitle lookup failed.', subtitlesUri);
    }
    final subtitlesBody = jsonDecode(subtitlesResponse.body);
    final rawItems = subtitlesBody is Map
        ? (subtitlesBody['items'] ?? subtitlesBody['subtitles'])
        : null;
    if (rawItems is! List) return const <ExternalSubtitle>[];
    return rawItems.whereType<Map>().map((row) {
      final id = row['id']?.toString() ?? '';
      final fileName = row['originalFilename']?.toString() ?? '';
      final release = row['releaseLabel']?.toString() ?? fileName;
      final ext = fileName.split('.').last.toLowerCase();
      return ExternalSubtitle(
        id: 'arabicsubs_$id',
        url: 'arabicsubs-proxy://subtitle/$id',
        flagUrl: '',
        format: const <String>{'srt', 'vtt', 'ass', 'ssa'}.contains(ext) ? ext : 'srt',
        encoding: 'UTF-8',
        display: 'Arabic',
        language: 'ar',
        media: isMovie ? 'movie' : 'tv',
        isHearingImpaired: row['hearingImpaired'] == true || row['hi'] == true,
        release: release,
        source: 'ArabicSubs',
      );
    }).where((subtitle) => subtitle.id != 'arabicsubs_').toList(growable: false);
  }

  static String _normaliseLanguageCode(String? value) {
    final input = (value ?? '').trim().toLowerCase();
    if (input.isEmpty) return '';
    final first = input.split(RegExp(r'[-_]')).first;
    if (first == 'ara' || first == 'arabic') return 'ar';
    if (first == 'eng' || first == 'english') return 'en';
    return first;
  }

  Future<List<ExternalSubtitle>> _searchOpenSubtitles({
    required String imdbId,
    required bool isMovie,
    String? preferredLanguageCode,
    int? season,
    int? episode,
  }) async {
    final numericImdbId = imdbId.replaceFirst(RegExp(r'^tt'), '');
    if (!RegExp(r'^\d+$').hasMatch(numericImdbId)) {
      return const <ExternalSubtitle>[];
    }

    // OpenSubtitles requires the path segments in alphabetical order for TV.
    final basePath = isMovie
        ? 'imdbid-$numericImdbId'
        : 'episode-$episode/imdbid-$numericImdbId/season-$season';

    Future<List<Map<String, dynamic>>> query(String path) async {
      final uri = Uri.parse('$_openSubtitlesBase/search/$path');
      final response = await _client.get(uri, headers: const <String, String>{
        'User-Agent': _openSubtitlesUserAgent,
        'X-User-Agent': _openSubtitlesUserAgent,
      }).timeout(_searchTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw http.ClientException(
          'OpenSubtitles returned HTTP ${response.statusCode}.',
          uri,
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! List) return const <Map<String, dynamic>>[];
      return decoded.whereType<Map>().map((row) => Map<String, dynamic>.from(row)).toList();
    }

    final queries = <Future<List<Map<String, dynamic>>>>[
      query(basePath).catchError((Object error) {
        debugPrint('[Subtitle][OpenSubtitles] Unfiltered query failed: $error');
        return const <Map<String, dynamic>>[];
      }),
      query('$basePath/sublanguageid-eng').catchError((Object error) {
        debugPrint('[Subtitle][OpenSubtitles] English query failed: $error');
        return const <Map<String, dynamic>>[];
      }),
    ];
    if (_normaliseLanguageCode(preferredLanguageCode) == 'ar') {
      queries.add(query('$basePath/sublanguageid-ara').catchError((Object error) {
        debugPrint('[Subtitle][OpenSubtitles] Arabic query failed: $error');
        return const <Map<String, dynamic>>[];
      }));
    }
    final responses = await Future.wait(queries);
    final byFileId = <String, Map<String, dynamic>>{};
    for (final row in responses.expand((rows) => rows)) {
      final id = row['IDSubtitleFile']?.toString().trim() ?? '';
      if (id.isNotEmpty) byFileId.putIfAbsent(id, () => row);
    }

    final parsed = <_OpenSubtitleRow>[];
    for (final row in byFileId.values) {
      final url = row['SubDownloadLink']?.toString().trim() ?? '';
      final format = row['SubFormat']?.toString().toLowerCase().trim() ?? '';
      if (!url.startsWith('http') || !const <String>{'srt', 'vtt'}.contains(format)) {
        continue;
      }
      parsed.add(_OpenSubtitleRow(
        id: row['IDSubtitleFile'].toString(),
        url: url,
        format: format,
        language: row['ISO639']?.toString().trim().toLowerCase() ?? '',
        display: row['LanguageName']?.toString().trim().isNotEmpty == true
            ? row['LanguageName'].toString().trim()
            : _languageName(row['ISO639']?.toString()),
        hearingImpaired: row['SubHearingImpaired'] == true ||
            row['SubHearingImpaired']?.toString() == '1',
        downloads: int.tryParse(row['SubDownloadsCnt']?.toString() ?? '') ?? 0,
        release: row['MovieReleaseName']?.toString().trim() ?? '',
      ));
    }

    final preferredCode = _normaliseLanguageCode(preferredLanguageCode);
    parsed.sort((a, b) {
      int rank(_OpenSubtitleRow row) {
        if (preferredCode.isNotEmpty &&
            _normaliseLanguageCode(row.language) == preferredCode) return 0;
        if (_normaliseLanguageCode(row.language) == 'en') return 1;
        return 2;
      }
      final languageOrder = rank(a).compareTo(rank(b));
      return languageOrder != 0 ? languageOrder : b.downloads.compareTo(a.downloads);
    });
    final perLanguage = <String, int>{};
    final results = <ExternalSubtitle>[];
    for (final row in parsed) {
      final key = row.display.toLowerCase();
      final count = perLanguage[key] ?? 0;
      if (count >= 3) continue;
      perLanguage[key] = count + 1;
      results.add(ExternalSubtitle(
        id: 'opensubtitles_${row.id}',
        url: row.url,
        flagUrl: '',
        format: row.format,
        encoding: 'gzip/auto',
        display: row.display,
        language: row.language,
        media: isMovie ? 'movie' : 'tv',
        isHearingImpaired: row.hearingImpaired,
        release: row.release,
        source: 'OpenSubtitles',
      ));
    }
    return results;
  }

  Future<List<ExternalSubtitle>> _searchSubSource({
    required String imdbId,
    required bool isMovie,
    int? season,
    int? episode,
    String? preferredLanguageCode,
  }) async {
    final titleLink = await _findSubSourceTitleLink(imdbId, isMovie: isMovie);
    if (titleLink == null) return const <ExternalSubtitle>[];

    final listPath = isMovie
        ? titleLink
        : '${titleLink.replaceFirst('/series/', '/subtitles/').replaceAll(RegExp(r'/+$'), '')}/season-$season';
    final languagePairs = _subSourceLanguages(preferredLanguageCode);
    final episodePattern = !isMovie ? _episodePattern(season!, episode!) : null;

    final languageResults = await Future.wait(languagePairs.map((language) async {
      try {
        final uri = Uri.parse('$_subSourceBase$listPath').replace(
          queryParameters: <String, String>{'language': language.name},
        );
        final response = await _client.get(uri, headers: _subSourceHeaders)
            .timeout(_searchTimeout);
        if (response.statusCode < 200 || response.statusCode >= 300) return <ExternalSubtitle>[];
        final body = jsonDecode(response.body);
        if (body is! Map || body['subtitles'] is! List) return <ExternalSubtitle>[];
        final rows = (body['subtitles'] as List).whereType<Map>();
        final seenIds = <String>{};
        final candidates = <_SubSourceRow>[];
        for (final row in rows) {
          final id = row['id']?.toString() ?? '';
          final rowLanguage = row['language']?.toString().trim() ?? '';
          final release = row['release_info']?.toString() ?? '';
          final releaseType = row['release_type']?.toString().trim().toLowerCase();
          final link = row['link']?.toString() ?? '';
          final rawHi = row['hearing_impaired'];
          final hi = rawHi == true || rawHi?.toString() == '1';
          // The endpoint can return multiple languages even when a language
          // query was supplied. Do not label a foreign-language result with
          // the requested language code.
          if (rowLanguage.toLowerCase() != language.name.toLowerCase()) continue;
          if (id.isEmpty || link.isEmpty || !seenIds.add(id)) continue;
          if (releaseType == 'trailer') continue;
          if (episodePattern != null && !episodePattern.hasMatch(release)) continue;
          if (episodePattern != null && _episodeRange.hasMatch(release)) continue;
          candidates.add(_SubSourceRow(
            id: id,
            language: rowLanguage,
            release: release,
            hearingImpaired: hi,
            link: link,
          ));
        }
        return candidates.take(4).map((row) {
          final detailUrl = row.link.startsWith('http')
              ? row.link
              : '$_subSourceBase/subtitle/${row.link.replaceFirst(RegExp(r'^/+'), '')}';
          return ExternalSubtitle(
            id: 'subsource_${row.id}',
            url: detailUrl,
            flagUrl: '',
            format: 'auto',
            encoding: 'zip/auto',
            display: _languageName(language.code, fallback: row.language),
            language: language.code,
            media: isMovie ? 'movie' : 'tv',
            isHearingImpaired: row.hearingImpaired,
            release: row.release,
            source: 'SubSource',
          );
        }).toList(growable: false);
      } catch (_) {
        return <ExternalSubtitle>[];
      }
    }));
    return languageResults.expand((items) => items).toList(growable: false);
  }

  Future<String?> _findSubSourceTitleLink(
    String imdbId, {
    required bool isMovie,
  }) async {
    final uri = Uri.parse('$_subSourceBase/movie/search');
    final response = await _client.post(
      uri,
      headers: <String, String>{
        ..._subSourceHeaders,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'query': imdbId,
        'signal': '{}',
        'includeSeasons': false,
        'limit': 15,
      }),
    ).timeout(_searchTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final body = jsonDecode(response.body);
    if (body is! Map || body['results'] is! List) return null;
    for (final result in (body['results'] as List).whereType<Map>()) {
      final link = result['link']?.toString() ?? '';
      if (isMovie && link.startsWith('/subtitles/')) return link;
      if (!isMovie && link.startsWith('/series/')) return link;
    }
    return null;
  }

  static const Map<String, String> _subSourceLanguageNames = <String, String>{
    'ar': 'arabic', 'bg': 'bulgarian', 'zh': 'chinese', 'hr': 'croatian',
    'cs': 'czech', 'da': 'danish', 'nl': 'dutch', 'en': 'english',
    'et': 'estonian', 'fi': 'finnish', 'fr': 'french', 'de': 'german',
    'el': 'greek', 'he': 'hebrew', 'hi': 'hindi', 'hu': 'hungarian',
    'id': 'indonesian', 'it': 'italian', 'ja': 'japanese', 'ko': 'korean',
    'lv': 'latvian', 'lt': 'lithuanian', 'ms': 'malay', 'no': 'norwegian',
    'pl': 'polish', 'pt': 'portuguese', 'ro': 'romanian', 'ru': 'russian',
    'sr': 'serbian', 'sk': 'slovak', 'sl': 'slovenian', 'es': 'spanish',
    'sv': 'swedish', 'th': 'thai', 'tr': 'turkish', 'uk': 'ukrainian',
  };

  static List<_SubSourceLanguage> _subSourceLanguages(String? preferred) {
    String normalizeCode(String? value) => (value ?? '')
        .trim()
        .toLowerCase()
        .split(RegExp(r'[-_]'))
        .first;

    // OpenStream checks English and the device language. CineStream also
    // honors the currently selected app language; when that differs from the
    // Android locale, search both so changing the UI language never hides the
    // subtitles normally offered for the device language.
    final codes = <String>{
      normalizeCode(preferred),
      'ar',
      'en',
      normalizeCode(PlatformDispatcher.instance.locale.languageCode),
    }..remove('');
    final result = <_SubSourceLanguage>[];
    for (final code in codes) {
      final name = _subSourceLanguageNames[code];
      if (name != null) result.add(_SubSourceLanguage(name, code));
    }
    return result;
  }

  static String _languageName(String? code, {String fallback = 'Unknown'}) {
    final normalized = (code ?? '').trim().toLowerCase().split(RegExp(r'[-_]')).first;
    return _subSourceLanguageNames[normalized] ?? fallback;
  }

  static final RegExp _episodeRange = RegExp(
    r'e\d+\s*-\s*e?\d+',
    caseSensitive: false,
  );

  static RegExp _episodePattern(int season, int episode) => RegExp(
        '(s0*$season[ ._-]*e0*$episode(?!\\d))|'
        '((?<![a-z0-9])${season}x0*$episode(?!\\d))|'
        '((?<![a-z0-9])e0*$episode(?!\\d))',
        caseSensitive: false,
      );

  /// Downloads and normalizes an external track into a WebVTT memory source.
  /// For SubSource the public search result is a detail URL, not a file URL;
  /// the detail response must be exchanged for its short-lived download token.
  Future<BetterPlayerSubtitlesSource> convertToBetterPlayerSource(
    ExternalSubtitle subtitle, {
    int? subtitleNumber,
  }) async {
    final text = await _downloadAndNormalize(subtitle);
    var name = subtitle.display.trim().isEmpty ? subtitle.language : subtitle.display;
    if (subtitleNumber != null) name = '$name #$subtitleNumber';
    if (subtitle.isHearingImpaired && !name.toLowerCase().contains('(hi)')) {
      name = '$name (HI)';
    }
    if (subtitle.source.trim().isNotEmpty) name = '$name · ${subtitle.source}';
    return BetterPlayerSubtitlesSource(
      type: BetterPlayerSubtitlesSourceType.memory,
      name: name,
      content: text,
      selectedByDefault: false,
    );
  }

  Future<String> downloadAndNormalizeForPlayback(ExternalSubtitle subtitle) =>
      _downloadAndNormalize(subtitle);

  Future<String> _downloadAndNormalize(ExternalSubtitle subtitle) async {
    final client = _client;
    var downloadUrl = subtitle.url;
    final headers = <String, String>{
      'User-Agent': 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36',
      'Accept': '*/*',
    };

    if (subtitle.source == 'OpenSubtitles' &&
        subtitle.url.startsWith('opensubtitles-v1://')) {
      if (_openSubtitlesApiKey.isEmpty) {
        throw StateError('OpenSubtitles API key is not configured.');
      }
      final fileId = int.tryParse(Uri.parse(subtitle.url).pathSegments.last);
      if (fileId == null || fileId <= 0) {
        throw const FormatException('Invalid OpenSubtitles file id.');
      }
      final downloadUri = Uri.parse('$_openSubtitlesV1Base/download');
      final tokenResponse = await client.post(
        downloadUri,
        headers: <String, String>{
          'Api-Key': _openSubtitlesApiKey,
          'User-Agent': 'CineStream PRO v1.0',
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{'file_id': fileId}),
      ).timeout(_downloadTimeout);
      if (tokenResponse.statusCode < 200 || tokenResponse.statusCode >= 300) {
        throw http.ClientException(
          'OpenSubtitles download request returned HTTP ${tokenResponse.statusCode}.',
          downloadUri,
        );
      }
      final tokenBody = jsonDecode(tokenResponse.body);
      downloadUrl = tokenBody is Map ? tokenBody['link']?.toString() ?? '' : '';
      if (!downloadUrl.startsWith('http')) {
        throw const FormatException('OpenSubtitles returned no download link.');
      }
    } else if (subtitle.source == 'ArabicSubs' &&
        subtitle.url.startsWith('arabicsubs-proxy://')) {
      final id = Uri.parse(subtitle.url).pathSegments.last;
      final proxyUri = Uri.parse(
        '$_arabicSubsProxyUrl/subtitles/${Uri.encodeComponent(id)}/download',
      );
      final response = await client.get(proxyUri, headers: const {
        'Accept': '*/*',
      }).timeout(_downloadTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw http.ClientException('ArabicSubs proxy download failed.', proxyUri);
      }
      if (response.bodyBytes.length > _maxSubtitleDownloadBytes) {
        throw const FormatException('Subtitle download exceeds the size limit.');
      }
      return SubtitleFileNormalizer.normalizeBytes(response.bodyBytes);
    } else if (subtitle.source == 'SubSource') {
      final detailUri = Uri.parse(subtitle.url);
      final detailResponse = await client.get(detailUri, headers: _subSourceHeaders)
          .timeout(_downloadTimeout);
      if (detailResponse.statusCode < 200 || detailResponse.statusCode >= 300) {
        throw http.ClientException('SubSource detail returned HTTP ${detailResponse.statusCode}.', detailUri);
      }
      final detail = jsonDecode(detailResponse.body);
      final token = detail is Map
          ? (detail['subtitle'] is Map
              ? (detail['subtitle'] as Map)['download_token']?.toString()
              : null)
          : null;
      if (token == null || token.trim().isEmpty) {
        throw const FormatException('SubSource did not return a download token.');
      }
      downloadUrl = '$_subSourceBase/subtitle/download/${Uri.encodeComponent(token)}';
      headers.addAll(_subSourceHeaders);
    } else if (subtitle.source == 'OpenSubtitles' &&
        subtitle.url.startsWith('http')) {
      headers.addAll(const <String, String>{
        'User-Agent': _openSubtitlesUserAgent,
      });
    } else if (subtitle.source == 'SubDL') {
      headers.addAll(const <String, String>{'User-Agent': 'CineStream PRO/1.0'});
    }

    final uri = Uri.parse(downloadUrl);
    final response = await client.get(uri, headers: headers).timeout(_downloadTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException('Subtitle download returned HTTP ${response.statusCode}.', uri);
    }
    if (response.bodyBytes.length > _maxSubtitleDownloadBytes) {
      throw const FormatException('Subtitle download exceeds the size limit.');
    }
    return SubtitleFileNormalizer.normalizeBytes(response.bodyBytes);
  }

  static const Map<String, String> _subSourceHeaders = <String, String>{
    'User-Agent': 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Origin': 'https://subsource.net',
    'Referer': 'https://subsource.net/',
  };

  static List<ExternalSubtitle> _mergeAndSort(
    Iterable<ExternalSubtitle> items,
    String? preferredLanguageCode,
  ) {
    final preferred = _normaliseLanguageCode(preferredLanguageCode);
    final ordered = items.where((item) {
      final url = item.url.trim();
      final isInternalDownload =
          (item.source == 'OpenSubtitles' &&
              url.startsWith('opensubtitles-v1://')) ||
          (item.source == 'ArabicSubs' &&
              url.startsWith('arabicsubs-proxy://'));
      return url.isNotEmpty && (url.startsWith('http') || isInternalDownload);
    }).toList(growable: true);

    // Apply language and provider priority before BOTH URL and release
    // de-duplication. This makes SubSource win even when two adapters expose
    // the same download URL or the same release record.
    ordered.sort((a, b) {
      int languageRank(ExternalSubtitle subtitle) {
        final language = _normaliseLanguageCode(subtitle.language);
        if (preferred.isNotEmpty && language == preferred) return 0;
        if (language == 'en') return 1;
        return 2;
      }

      final languageOrder = languageRank(a).compareTo(languageRank(b));
      if (languageOrder != 0) return languageOrder;
      final sourceOrder = _sourceRank(
        a.source,
        languageCode: _normaliseLanguageCode(a.language),
      ).compareTo(_sourceRank(
        b.source,
        languageCode: _normaliseLanguageCode(b.language),
      ));
      if (sourceOrder != 0) return sourceOrder;
      return a.display.toLowerCase().compareTo(b.display.toLowerCase());
    });

    final seenUrls = <String>{};
    final seenReleases = <String>{};
    final merged = <ExternalSubtitle>[];
    for (final item in ordered) {
      if (!seenUrls.add(item.url.trim())) continue;
      final release = item.release.trim().toLowerCase();
      final language = _normaliseLanguageCode(item.language);
      if (release.isNotEmpty) {
        final key = '$language|$release|${item.isHearingImpaired}';
        if (!seenReleases.add(key)) continue;
      }
      merged.add(item);
    }
    return List<ExternalSubtitle>.unmodifiable(merged);
  }

  static int _sourceRank(
    String source, {
    required String languageCode,
  }) {
    if (languageCode == 'ar') {
      return switch (source) {
        // Arabic subtitle selection must prefer SubSource whenever it has a
        // usable result; the other Arabic providers are deterministic fallbacks.
        'SubSource' => 0,
        'OpenSubtitles' => 1,
        'SubDL' => 2,
        'ArabicSubs' => 3,
        _ => 4,
      };
    }
    return switch (source) {
      'OpenSubtitles' => 0,
      'SubSource' => 1,
      'SubDL' => 2,
      'ArabicSubs' => 3,
      _ => 4,
    };
  }

  @visibleForTesting
  static List<ExternalSubtitle> mergeSearchResultsForTesting(
    Iterable<ExternalSubtitle> items,
    String? preferredLanguageCode,
  ) => _mergeAndSort(items, preferredLanguageCode);

  @visibleForTesting
  static String? subSourceLanguageNameForTesting(String code) =>
      _subSourceLanguageNames[code.toLowerCase()];

  @visibleForTesting
  static RegExp episodePatternForTesting(int season, int episode) =>
      _episodePattern(season, episode);

  @visibleForTesting
  static String normaliseLanguageCodeForTesting(String? value) =>
      _normaliseLanguageCode(value);
}

class _OpenSubtitleRow {
  const _OpenSubtitleRow({
    required this.id,
    required this.url,
    required this.format,
    required this.language,
    required this.display,
    required this.hearingImpaired,
    required this.downloads,
    required this.release,
  });
  final String id;
  final String url;
  final String format;
  final String language;
  final String display;
  final bool hearingImpaired;
  final int downloads;
  final String release;
}

class _SubSourceLanguage {
  const _SubSourceLanguage(this.name, this.code);
  final String name;
  final String code;
}

class _SubSourceRow {
  const _SubSourceRow({
    required this.id,
    required this.language,
    required this.release,
    required this.hearingImpaired,
    required this.link,
  });
  final String id;
  final String language;
  final String release;
  final bool hearingImpaired;
  final String link;
}
