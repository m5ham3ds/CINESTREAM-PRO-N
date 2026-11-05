import 'package:dio/dio.dart';

import 'media_identity.dart';
import 'quickjs/quickjs_provider_runtime.dart';
import 'quickjs/quickjs_stream_mapper.dart';
import 'source_engine.dart';
import 'source_manifest.dart';

/// Executes Zangetsu-compatible JavaScript sources. Each provider's search,
/// episode matching and getVideoSources call follow Zangetsu's public JS
/// contract; source scripts are downloaded from the repository URL and run in
/// a sandboxed QuickJS runtime with a mediated HTTP bridge.
class QuickJsSourceEngine extends SourceEngine {
  QuickJsSourceEngine({QuickJsProviderRuntime? runtime, Dio? dio})
      : _runtime = runtime ?? QuickJsProviderRuntime(dio: dio);

  final QuickJsProviderRuntime _runtime;

  @override
  SourceEngineKind get kind => SourceEngineKind.javascript;

  @override
  Future<UnifiedSourceResult> resolve({
    required SourceManifest source,
    required MediaIdentity media,
    CancelToken? cancelToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final info = await _runtime.call(
        source,
        'getInfo',
        const <Object?>[],
        timeout: const Duration(seconds: 15),
        cancelToken: cancelToken,
      );
      if (info is! Map) {
        throw const FormatException('Provider getInfo() did not return a metadata object.');
      }
      final declaredType = (info['type'] ?? _providerType(source))
          .toString()
          .trim()
          .toLowerCase();
      final supportsRequestedType = switch (declaredType) {
        'all' || 'multi' || 'universal' || '' => true,
        'movie' || 'movies' || 'film' => media.type == UnifiedMediaType.movie,
        'series' || 'tv' || 'show' || 'shows' =>
          media.type == UnifiedMediaType.series,
        'anime' || 'anime-only' || 'anime_only' =>
          media.type == UnifiedMediaType.anime || media.isAnimeContent,
        _ => false,
      };
      if (!supportsRequestedType) {
        throw FormatException(
          'Provider ${source.name} declares type "$declaredType" and cannot resolve ${media.type.name}.',
        );
      }
      final searchResults = await _search(
        source,
        media,
        cancelToken,
        category: media.type == UnifiedMediaType.movie ? 'movie' : 'sub',
      );
      final match = _bestMatch(searchResults, media);
      if (match == null) {
        stopwatch.stop();
        return UnifiedSourceResult(
          errorMessage: 'No matching title was found by ${source.name}.',
          elapsed: stopwatch.elapsed,
        );
      }

      String targetUrl = _readString(match, const <String>['url', 'link', 'id']);
      if (targetUrl.isEmpty) {
        throw const FormatException('Provider search result does not contain a playable title URL.');
      }
      if (media.type != UnifiedMediaType.movie) {
        targetUrl = await _resolveEpisodeUrl(source, media, targetUrl, cancelToken);
      }
      final rawStreams = await _runtime.call(
        source,
        'getVideoSources',
        <Object?>[targetUrl, false],
        timeout: const Duration(seconds: 60),
        cancelToken: cancelToken,
      );
      final streams = mapQuickJsVideoSources(source, rawStreams);
      stopwatch.stop();
      if (streams.isEmpty) {
        return UnifiedSourceResult(
          errorMessage: '${source.name} getVideoSources() returned no playable HTTP(S) streams. '
              'Check the provider result shape, host extractor, and required request headers.',
          elapsed: stopwatch.elapsed,
        );
      }
      return UnifiedSourceResult(streams: streams, elapsed: stopwatch.elapsed);
    } on DioException catch (error) {
      stopwatch.stop();
      return UnifiedSourceResult(
        errorMessage: error.message ?? 'JavaScript provider network request failed.',
        elapsed: stopwatch.elapsed,
      );
    } catch (error) {
      stopwatch.stop();
      return UnifiedSourceResult(errorMessage: error.toString(), elapsed: stopwatch.elapsed);
    }
  }

  String _providerType(SourceManifest source) =>
      (source.engine.config['providerType'] ?? 'all').toString().toLowerCase();

  Future<List<Map<String, dynamic>>> _search(
    SourceManifest source,
    MediaIdentity media,
    CancelToken? cancelToken, {
    required String category,
  }) async {
    final terms = <String>{
      media.title.trim(),
      if ((media.originalTitle ?? '').trim().isNotEmpty) media.originalTitle!.trim(),
    }.where((value) => value.isNotEmpty).toList(growable: false);
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final term in terms) {
      final result = await _runtime.call(
        source,
        'search',
        <Object?>[term, 1, <String, dynamic>{'category': category}],
        timeout: const Duration(seconds: 30),
        cancelToken: cancelToken,
      );
      if (result is! List) continue;
      for (final item in result.whereType<Map>()) {
        final map = Map<String, dynamic>.from(item);
        final key = _readString(map, const <String>['url', 'link', 'id']);
        if (key.isNotEmpty && seen.add(key)) out.add(map);
      }
      if (out.length >= 40) break;
    }
    return out;
  }

  Map<String, dynamic>? _bestMatch(
    List<Map<String, dynamic>> items,
    MediaIdentity media,
  ) {
    Map<String, dynamic>? best;
    var bestScore = 0.0;
    for (final item in items) {
      final candidates = <String>[
        for (final key in const <String>['title', 'name', 'englishTitle', 'originalTitle'])
          if (item[key] != null) item[key].toString(),
      ];
      var score = 0.0;
      for (final candidate in candidates) {
        score = score > _titleScore(media.title, candidate)
            ? score
            : _titleScore(media.title, candidate);
        if ((media.originalTitle ?? '').trim().isNotEmpty) {
          final originalScore = _titleScore(media.originalTitle!, candidate);
          if (originalScore > score) score = originalScore;
        }
      }
      final itemYear = int.tryParse('${item['year'] ?? item['releaseYear'] ?? ''}');
      if (media.year != null && itemYear != null && media.year != itemYear) {
        score -= 0.2;
      }
      if (score > bestScore) {
        bestScore = score;
        best = item;
      }
    }
    return bestScore >= 0.78 ? best : null;
  }

  double _titleScore(String first, String second) {
    final a = _normalizeTitle(first);
    final b = _normalizeTitle(second);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    if (a.startsWith(b) || b.startsWith(a)) return 0.86;
    final aTokens = a.split(' ').toSet();
    final bTokens = b.split(' ').toSet();
    if (aTokens.isEmpty || bTokens.isEmpty) return 0;
    final common = aTokens.intersection(bTokens).length;
    return common / aTokens.union(bTokens).length;
  }

  // Keep all writing systems. The previous ASCII/Arabic-only filter erased
  // Japanese, Korean, Chinese and Cyrillic titles before fuzzy matching.
  String _normalizeTitle(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)'), ' ')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<String> _resolveEpisodeUrl(
    SourceManifest source,
    MediaIdentity media,
    String seriesUrl,
    CancelToken? cancelToken,
  ) async {
    if (!media.isEpisode) {
      throw const FormatException('Season and episode numbers are required for series sources.');
    }
    // Zangetsu allows getEpisodes() to be omitted when getDetail() already
    // returns an `episodes` array. Prefer the richer detail response, then
    // fall back to the optional method for providers that split the calls.
    List<dynamic> episodeItems = const <dynamic>[];
    try {
      final detail = await _runtime.call(
        source,
        'getDetail',
        <Object?>[seriesUrl],
        timeout: const Duration(seconds: 30),
        cancelToken: cancelToken,
      );
      if (detail is Map && detail['episodes'] is List) {
        episodeItems = detail['episodes'] as List<dynamic>;
      }
    } catch (_) {
      // getDetail is optional in the Zangetsu contract. Providers that only
      // implement getEpisodes() must remain usable.
    }
    if (episodeItems.isEmpty) {
      final episodes = await _runtime.call(
        source,
        'getEpisodes',
        <Object?>[seriesUrl, <String, dynamic>{'category': 'sub'}],
        timeout: const Duration(seconds: 30),
        cancelToken: cancelToken,
      );
      if (episodes is List) episodeItems = episodes;
    }
    if (episodeItems.isEmpty) {
      throw const FormatException(
        'Provider did not return an episode list from getDetail() or getEpisodes().',
      );
    }
    Map<String, dynamic>? match;
    for (final raw in episodeItems.whereType<Map>()) {
      final item = Map<String, dynamic>.from(raw);
      final number = _episodeNumber(item);
      final itemSeason = _optionalInt(
        item,
        const <String>['season', 'seasonNumber', 'season_number'],
      );
      final seasonMatches = itemSeason == null ||
          media.seasonNumber == null ||
          itemSeason == media.seasonNumber;
      if (number == media.episodeNumber && seasonMatches) {
        match = item;
        break;
      }
    }
    if (match == null) {
      throw FormatException('Episode ${media.episodeNumber} was not found on ${source.name}.');
    }
    final episodeUrl = _readString(match, const <String>['url', 'link', 'id']);
    if (episodeUrl.isEmpty) {
      throw const FormatException('Matched episode does not contain a source URL.');
    }
    return episodeUrl;
  }

  int? _optionalInt(Map<String, dynamic> item, List<String> keys) {
    for (final key in keys) {
      final value = item[key];
      if (value is num) return value.toInt();
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }

  int? _episodeNumber(Map<String, dynamic> item) {
    for (final key in const <String>['number', 'episode', 'episodeNumber', 'episode_number']) {
      final value = item[key];
      if (value is num) return value.toInt();
      if (value != null) {
        final found = RegExp(r'\d+(?:\.\d+)?').firstMatch(value.toString());
        if (found != null) return double.tryParse(found.group(0)!)?.toInt();
      }
    }
    final title = (item['title'] ?? '').toString();
    final found = RegExp(r'(?:episode|ep\.?|الحلقة)?\s*(\d+)', caseSensitive: false)
        .firstMatch(title);
    return found == null ? null : int.tryParse(found.group(1)!);
  }

  String _readString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key]?.toString().trim();
      if (value != null && value.isNotEmpty && value != 'null') return value;
    }
    return '';
  }

}

