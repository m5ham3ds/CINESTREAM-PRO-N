import 'unified/source_manifest.dart';
import 'unified/media_identity.dart';

enum VideoProviderType {
  directVixSrc,
  scraperApi,
  unifiedSources,
  unifiedSource,
}

class VideoProvider {
  const VideoProvider({
    required this.fullName,
    required this.codeName,
    this.alias,
    this.content,
    this.type = VideoProviderType.directVixSrc,
    this.apiId,
    this.sourceManifest,
  });

  /// Provider name supplied by the service. This is kept for diagnostics.
  final String fullName;

  /// A unique in-app identifier. Scraper IDs are namespaced so they cannot
  /// collide with a direct provider that has the same upstream ID.
  final String codeName;

  /// User-facing name supplied by the scraper API.
  final String? alias;

  /// Human-readable catalogue/language coverage supplied by the scraper.
  final String? content;
  final VideoProviderType type;
  final String? apiId;
  final SourceManifest? sourceManifest;

  String get displayName {
    final value = alias?.trim();
    return value == null || value.isEmpty ? fullName : value;
  }

  /// One-line description of what this source can stream. Prefers the
  /// scraper-supplied [content] blurb and falls back to the provider kind for
  /// sources that do not advertise one, such as [directVixSrc].
  bool get isFallback =>
      sourceManifest?.isFallback == true ||
      sourceManifest?.engine.kind == SourceEngineKind.vidkingWebView;

  bool get isAnimeOnly => sourceManifest?.isAnimeOnly == true;

  /// Multi-content sources remain eligible. Only sources that explicitly
  /// declare anime-only support are skipped for live-action movies/series.
  bool supportsMediaType(UnifiedMediaType mediaType) =>
      !isAnimeOnly || mediaType == UnifiedMediaType.anime;

  bool supportsMedia(MediaIdentity media) =>
      sourceManifest?.supportsMedia(media) ?? true;

  String get contentDescription {
    final value = content?.trim();
    if (value != null && value.isNotEmpty) return value;
    return switch (type) {
      VideoProviderType.directVixSrc => 'Direct provider',
      VideoProviderType.scraperApi => 'Streaming provider',
      VideoProviderType.unifiedSources =>
        'Repository sources · Stremio and Vidking',
      VideoProviderType.unifiedSource => _sourceDescription,
    };
  }

  String get _sourceDescription {
    final source = sourceManifest;
    if (source == null) return 'Repository source';
    final details = <String>[
      source.engine.rawType,
      if (source.language.trim().isNotEmpty) source.language.trim(),
    ].where((part) => part.trim().isNotEmpty).toList(growable: false);
    return details.isEmpty ? 'Repository source' : details.join(' · ');
  }

  factory VideoProvider.unifiedSource(SourceManifest source) {
    return VideoProvider(
      fullName: source.name,
      alias: source.name,
      content: <String>[
        source.engine.rawType,
        if (source.language.trim().isNotEmpty) source.language.trim(),
      ].join(' · '),
      codeName: 'unified:source:${source.stableKey}',
      type: VideoProviderType.unifiedSource,
      sourceManifest: source,
    );
  }

  static const unifiedSources = VideoProvider(
    fullName: 'Unified Sources',
    alias: 'Unified Sources',
    codeName: 'unified:sources',
    type: VideoProviderType.unifiedSources,
  );

  static const directVixSrc = VideoProvider(
    fullName: 'VixSrc',
    alias: 'VixSrc Direct',
    codeName: 'direct:vixsrc',
    type: VideoProviderType.directVixSrc,
    apiId: 'vixsrc',
  );

  factory VideoProvider.scraper({
    required String id,
    required String name,
    String? alias,
    String? content,
  }) {
    return VideoProvider(
      fullName: name,
      alias: alias,
      content: content,
      codeName: 'scraper:$id',
      type: VideoProviderType.scraperApi,
      apiId: id,
    );
  }
}

/// Applies a persisted provider preference to the providers currently
/// advertised by the backend.
///
/// Missing providers are ignored. Newly advertised providers are inserted at
/// their indexes in the current backend catalog, while providers already in
/// the preference retain their custom relative order. Provider codes, rather
/// than display names, keep the preference stable when names change.
abstract final class VideoProviderOrder {
  static List<VideoProvider> apply(
    Iterable<VideoProvider> availableProviders,
    Iterable<String> preferredCodes,
  ) {
    // Materialize a de-duplicated catalog first so a malformed duplicate API
    // entry cannot shift the insertion index of providers that follow it.
    final catalog = <VideoProvider>[];
    final remaining = <String, VideoProvider>{};
    for (final provider in availableProviders) {
      if (!remaining.containsKey(provider.codeName)) {
        catalog.add(provider);
        remaining[provider.codeName] = provider;
      }
    }

    final ordered = <VideoProvider>[];
    for (final code in preferredCodes) {
      final provider = remaining.remove(code);
      if (provider != null) ordered.add(provider);
    }

    // Anything left was not known when the preference was saved. Place each
    // such provider at its API index instead of demoting it behind the user's
    // entire custom order. Increasing catalog indexes also preserve API order
    // when several providers are introduced at once.
    for (var catalogIndex = 0; catalogIndex < catalog.length; catalogIndex++) {
      final provider = catalog[catalogIndex];
      if (remaining.remove(provider.codeName) == null) continue;

      final insertionIndex =
          catalogIndex < ordered.length ? catalogIndex : ordered.length;
      ordered.insert(insertionIndex, provider);
    }
    return ordered;
  }
}
