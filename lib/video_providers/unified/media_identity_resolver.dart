import 'package:flixquest/api/endpoints.dart';
import 'package:flixquest/core/cache/cache_policy.dart';
import 'package:flixquest/core/network/network_runtime.dart';

import 'media_identity.dart';

typedef TmdbImdbIdLookup = Future<String?> Function(
  UnifiedMediaType type,
  int tmdbId,
);

/// Enriches a TMDB media identity with provider identifiers before source
/// engines run. This mirrors OpenStream's IdMappingService for IMDb while
/// leaving anime-specific AniList/MAL mapping to OpenStreamAnimeSourceEngine.
///
/// The persistent HTTP cache is the durable cache: successful `external_ids`
/// responses are fresh for 30 days and can be used stale for up to 180 days
/// when TMDB is unreachable. The in-memory layer only coalesces requests and
/// avoids duplicate lookups during the current process.
class MediaIdentityResolver {
  MediaIdentityResolver({
    TmdbImdbIdLookup? lookup,
    DateTime Function()? clock,
  })  : _lookup = lookup ?? _lookupTmdb,
        _clock = clock ?? DateTime.now;

  static const Duration mappingTtl = Duration(days: 30);
  static const CachePolicy _externalIdCachePolicy = CachePolicy(
    scope: 'tmdb',
    fresh: mappingTtl,
    maxStale: Duration(days: 150),
  );
  static const String _endpointLanguage = 'en-US';

  final TmdbImdbIdLookup _lookup;
  final DateTime Function() _clock;
  final Map<String, _CachedImdbId> _cache = <String, _CachedImdbId>{};
  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};

  /// Returns the same identity unless a valid IMDb identifier is discovered.
  /// Lookup errors are intentionally non-fatal: Vidking, Web Embed and
  /// QuickJS providers can still resolve using TMDB IDs or their own search.
  Future<MediaIdentity> enrich(MediaIdentity identity) async {
    if (identity.imdbId != null) return identity;
    final tmdbId = identity.tmdbId;
    if (tmdbId == null || tmdbId <= 0) return identity;

    final key = '${identity.type == UnifiedMediaType.movie ? 'movie' : 'tv'}:$tmdbId';
    final imdbId = await _resolveImdbId(key, identity.type, tmdbId);
    if (imdbId == null || identity.imdbId != null) return identity;

    return identity.copyWithExternalIds(<String, String>{
      ...identity.externalIds,
      'imdb': imdbId,
    });
  }

  Future<String?> _resolveImdbId(
    String key,
    UnifiedMediaType type,
    int tmdbId,
  ) async {
    final cached = _cache[key];
    if (cached != null) {
      final age = _clock().difference(cached.resolvedAt);
      if (age >= Duration.zero && age < mappingTtl) return cached.imdbId;
      _cache.remove(key);
    }

    final pending = _inFlight[key];
    if (pending != null) return pending;

    late final Future<String?> future;
    try {
      future = _lookup(type, tmdbId).then((rawId) {
        final imdbId = _validImdbId(rawId);
        if (imdbId != null) {
          _cache[key] = _CachedImdbId(imdbId, _clock());
        }
        return imdbId;
      }).catchError((Object _) => null);
    } catch (_) {
      return null;
    }

    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }
  }

  static String? _validImdbId(String? value) {
    final candidate = value?.trim();
    if (candidate == null || !RegExp(r'^tt\d+$').hasMatch(candidate)) {
      return null;
    }
    return candidate;
  }

  static Future<String?> _lookupTmdb(
    UnifiedMediaType type,
    int tmdbId,
  ) async {
    final endpoint = type == UnifiedMediaType.movie
        ? Endpoints.getExternalLinksForMovie(tmdbId, _endpointLanguage)
        : Endpoints.getExternalLinksForTV(tmdbId, _endpointLanguage);
    try {
      final result = await NetworkRuntime.tmdb.getJson(
        endpoint,
        policy: _externalIdCachePolicy,
        timeout: const Duration(seconds: 8),
      );
      final body = result.getOrElse((_) => const <String, dynamic>{});
      return _validImdbId(body['imdb_id']?.toString());
    } catch (_) {
      // Identifier enrichment is optional and must never block other engines.
      return null;
    }
  }
}

class _CachedImdbId {
  const _CachedImdbId(this.imdbId, this.resolvedAt);

  final String imdbId;
  final DateTime resolvedAt;
}
