/// Stable identity passed to every source engine.
///
/// TMDB remains the catalogue authority in FlixQuest. External identifiers are
/// carried separately because source ecosystems (notably Stremio) often need an
/// IMDb/AniList/MAL identifier rather than a TMDB integer.
enum UnifiedMediaType { movie, series, anime }

class MediaIdentity {
  const MediaIdentity({
    required this.type,
    required this.title,
    this.originalTitle,
    this.year,
    this.tmdbId,
    this.seasonNumber,
    this.episodeNumber,
    this.episodeTmdbId,
    this.episodeAirDate,
    this.externalIds = const <String, String>{},
    this.isAnimeContent = false,
  });

  final UnifiedMediaType type;
  final String title;
  final String? originalTitle;
  final int? year;
  final int? tmdbId;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? episodeTmdbId;
  final String? episodeAirDate;
  final Map<String, String> externalIds;

  /// True for anime movies and anime episodes. Kept separate from [type] so
  /// anime feature films retain TMDB/Stremio movie routing and AniZip MOVIE
  /// mapping while anime-only providers remain eligible.
  final bool isAnimeContent;

  bool get isEpisode =>
      type != UnifiedMediaType.movie &&
      seasonNumber != null &&
      episodeNumber != null;

  /// Stremio's public stream protocol accepts `movie` and `series` types.
  String get stremioType =>
      type == UnifiedMediaType.movie ? 'movie' : 'series';

  /// A source-specific ID explicitly supplied by the catalogue/mapping layer.
  /// It may use any identifier prefix that a Stremio add-on advertises.
  String? get explicitStremioId => _firstNonEmpty(<String?>[
        externalIds['stremio'],
      ]);

  /// Returns a validated IMDb ID, not an arbitrary external identifier.
  String? get imdbId {
    final value = _firstNonEmpty(<String?>[
      externalIds['imdb'],
      externalIds['imdbId'],
    ]);
    return value != null && RegExp(r'^tt\d+$').hasMatch(value) ? value : null;
  }

  /// Returns an explicit Stremio ID, or an IMDb-compatible ID when available.
  /// TMDB IDs are never guessed here; the add-on's `idPrefixes` must opt in.
  String? get stremioId {
    final explicit = explicitStremioId ?? imdbId;
    if (explicit == null) return null;
    if (type == UnifiedMediaType.movie || !isEpisode) return explicit;
    final episodeSuffix = ':$seasonNumber:$episodeNumber';
    return explicit.endsWith(episodeSuffix)
        ? explicit
        : '$explicit$episodeSuffix';
  }


  /// Returns a copy with merged external provider identifiers. Existing
  /// values are preserved unless the caller supplies a replacement.
  MediaIdentity copyWithExternalIds(Map<String, String> values) =>
      MediaIdentity(
        type: type,
        title: title,
        originalTitle: originalTitle,
        year: year,
        tmdbId: tmdbId,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        episodeTmdbId: episodeTmdbId,
        episodeAirDate: episodeAirDate,
        externalIds: Map<String, String>.unmodifiable(values),
        isAnimeContent: isAnimeContent,
      );

  String get normalizedTitle => title.trim().toLowerCase();

  /// Stable local-only key for playback history/cache. It separates movies,
  /// seasons, episodes, and anime classification without putting the title or
  /// any signed stream URL in a storage key.
  String get playbackCacheKey => <String>[
        type.name,
        tmdbId?.toString() ?? normalizedTitle,
        seasonNumber?.toString() ?? '-',
        episodeNumber?.toString() ?? '-',
        isAnimeContent ? 'anime' : 'general',
      ].join(':');

  static String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }
}
