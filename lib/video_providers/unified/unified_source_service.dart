import 'package:dio/dio.dart';

import 'media_identity.dart';
import 'media_identity_resolver.dart';
import 'source_engine.dart';
import 'source_manifest.dart';
import 'source_repository_manager.dart';
import 'stream_option.dart';

class UnifiedSourceSearchResult {
  const UnifiedSourceSearchResult({
    required this.repositorySnapshot,
    required this.attempts,
    required this.streams,
  });

  final SourceRepositorySyncResult repositorySnapshot;
  final List<UnifiedSourceAttempt> attempts;
  final List<UnifiedStreamOption> streams;

  int get successfulSourceCount =>
      attempts.where((attempt) => attempt.result.success).length;
}

/// Application-facing facade for repository management and unified stream
/// lookup. Movie and episode loaders use this service behind the existing
/// player adapter, keeping engine-specific details out of the UI.
class UnifiedSourceService {
  UnifiedSourceService({
    SourceRepositoryManager? repositories,
    SourceEngineRegistry? engines,
    MediaIdentityResolver? identityResolver,
  })  : _repositories = repositories ?? SourceRepositoryManager(),
        _engines = engines ?? SourceEngineRegistry.standard(),
        _identityResolver = identityResolver ?? MediaIdentityResolver();

  final SourceRepositoryManager _repositories;
  final SourceEngineRegistry _engines;
  final MediaIdentityResolver _identityResolver;

  bool supportsSource(SourceManifest source) => _engines.supports(source);

  /// Returns installed sources with a registered runtime. Unsupported
  /// manifest types stay visible in repository management, but are not
  /// advertised as playable providers.
  Future<List<SourceManifest>> installedPlayableSources() async {
    final snapshot = await _repositories.sync();
    final sources = snapshot.sources
        .where((source) => source.status != 0 && _engines.supports(source))
        .toList()
      ..sort((a, b) {
        final byPriority = a.engine.priority.compareTo(b.engine.priority);
        return byPriority != 0 ? byPriority : a.stableKey.compareTo(b.stableKey);
      });
    return sources;
  }

  Future<void> addRepository(String url) => _repositories.addRepository(url);

  Future<void> removeRepository(String url) =>
      _repositories.removeRepository(url);

  Future<void> installSource(SourceManifest source) =>
      _repositories.installSource(source);

  Future<void> uninstallSource(SourceManifest source) =>
      _repositories.uninstallSource(source);

  Future<List<String>> repositoryUrls() => _repositories.repositoryUrls();

  Future<Set<String>> installedSourceKeys() =>
      _repositories.installedSourceKeys();

  Future<Set<String>> disabledDefaultSourceKeys() =>
      _repositories.disabledDefaultSourceKeys();

  Future<SourceRepositorySyncResult> refreshRepositories({
    bool forceRefresh = true,
  }) =>
      _repositories.sync(forceRefresh: forceRefresh);

  Future<String> exportConfiguration() =>
      _repositories.exportConfiguration();

  Future<void> importConfiguration(String raw) =>
      _repositories.importConfiguration(raw);

  Future<UnifiedSourceSearchResult> search({
    required MediaIdentity media,
    CancelToken? cancelToken,
    SourceAttemptCallback? onAttempt,
    SourceEngineStartCallback? onSourceStart,
    SourceRepositorySyncResult? repositorySnapshot,
    SourceManifest? onlySource,
    Iterable<SourceManifest>? onlySources,
  }) async {
    if (onlySource != null && onlySources != null) {
      throw ArgumentError('Use either onlySource or onlySources, not both.');
    }
    final snapshot = repositorySnapshot ?? await _repositories.sync();
    final selectedKeys = onlySources?.map((source) => source.stableKey).toSet();
    final candidates = snapshot.sources.where((source) {
      if (onlySource != null && source.stableKey != onlySource.stableKey) {
        return false;
      }
      if (selectedKeys != null && !selectedKeys.contains(source.stableKey)) {
        return false;
      }
      // A repository status of 0 explicitly marks the source as down.
      // Keep it visible in management, but do not spend playback time on it.
      if (source.status == 0) return false;
      // Never dispatch a manifest to an engine that is not registered or
      // does not implement its declared type. The catalogue may still show it.
      return _engines.supports(source);
    }).toList(growable: false)
      ..sort((a, b) {
        final byPriority = a.engine.priority.compareTo(b.engine.priority);
        return byPriority != 0 ? byPriority : a.stableKey.compareTo(b.stableKey);
      });

    // Resolve exactly one provider at a time. The older implementation split
    // Stremio and non-Stremio into separate Future.wait branches, which meant
    // both branches could run simultaneously and start multiple source requests.
    // IMDb enrichment is performed only when the priority queue reaches an
    // add-on that needs it, so direct sources are never blocked by that lookup.
    var resolvedIdentity = media;
    var imdbLookupAttempted = media.imdbId != null;
    final attempts = <UnifiedSourceAttempt>[];
    for (final source in candidates) {
      if (cancelToken?.isCancelled == true) break;

      if (_needsImdbId(source) && resolvedIdentity.imdbId == null &&
          !imdbLookupAttempted) {
        imdbLookupAttempted = true;
        try {
          resolvedIdentity = await _identityResolver
              .enrich(media)
              .timeout(const Duration(seconds: 8), onTimeout: () => media);
        } catch (_) {
          // The provider still gets a chance with the IDs already available.
          resolvedIdentity = media;
        }
      }

      final sourceIdentity = _needsImdbId(source) ? resolvedIdentity : media;
      final sourceAttempts = await _engines.resolveMany(
        sources: <SourceManifest>[source],
        media: sourceIdentity,
        maxConcurrency: 1,
        cancelToken: cancelToken,
        onSourceStart: onSourceStart,
        onAttempt: onAttempt,
      );
      attempts.addAll(sourceAttempts);
    }
    // Keep source attribution and distinct request/audio/subtitle metadata
    // intact. Exact duplicate results from the same provider are collapsed.
    final streams = <UnifiedStreamOption>[];
    final seen = <String>{};
    for (final attempt in attempts) {
      for (final stream in attempt.result.streams) {
        final headerKey = stream.headers.entries
            .map((entry) => '${entry.key.toLowerCase()}:${entry.value}')
            .toList()
          ..sort();
        final subtitleKey = stream.subtitles.map((track) {
          final trackHeaders = track.headers.entries
              .map((entry) => '${entry.key.toLowerCase()}:${entry.value}')
              .toList()
            ..sort();
          return <String>[
            track.url,
            track.language,
            track.format ?? '',
            track.isDefault.toString(),
            trackHeaders.join('&'),
          ].join(':');
        }).toList()
          ..sort();
        final key = <String>[
          stream.providerId,
          stream.url,
          headerKey.join('&'),
          stream.label ?? '',
          stream.quality ?? '',
          stream.container.name,
          stream.audioKind.name,
          stream.audioLanguage ?? '',
          subtitleKey.join('&'),
          stream.subtitleOffsetSeconds?.toString() ?? '',
          stream.subtitleOffsetAfterSeconds?.toString() ?? '',
          stream.proxyUrl ?? '',
          stream.drmType ?? '',
        ].join('\u001f');
        if (seen.add(key)) streams.add(stream);
      }
    }

    return UnifiedSourceSearchResult(
      repositorySnapshot: snapshot,
      attempts: attempts,
      streams: streams,
    );
  }

  bool _needsImdbId(SourceManifest source) {
    if (source.engine.kind != SourceEngineKind.stremio) return false;
    final rawPrefixes = source.engine.config['idPrefixes'];
    if (rawPrefixes is! List) return true; // Stremio default is IMDb.
    return rawPrefixes.any((value) {
      final prefix = value.toString().trim().toLowerCase();
      return prefix == 'imdb' || prefix.startsWith('tt');
    });
  }
}
