import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:better_player_plus/better_player_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../../constants/app_constants.dart';
import '../../../functions/language_names.dart';
import '../../../models/external_subtitles.dart';
import '../../../models/movie_stream_metadata.dart';
import '../../../models/tv_stream_metadata.dart';
import '../../../services/external_subtitle_service.dart';
import '../../../services/subtitle_playback_store.dart';
import '../../../ui_components/app_ui_components.dart';
import 'player_sheet_ui.dart';
import 'player_feedback_ui.dart';
import '../../../mobile/widgets/page_kit.dart';

class PlayerExternalSubtitles {
  PlayerExternalSubtitles({SubtitlePlaybackStore? store})
      : _store = store ?? SubtitlePlaybackStore();

  final SubtitlePlaybackStore _store;
  String? _mediaCacheKey;
  String _preferredLanguageCode = 'ar';
  bool _automaticPreferredSearchStarted = false;
  bool _preferredSubtitleRestored = false;
  BetterPlayerSubtitlesSource? _preferredRestoredSource;
  List<ExternalSubtitle> _availableExternalSubtitles = [];
  final List<ExternalSubtitle> _selectedExternalSubtitles = [];
  bool _isLoadingExternalSubtitles = false;
  bool _isExternalSubtitlesMenuOpen = false;
  bool _hasAutoLoadedExternalSubtitles = false;
  final Set<String> _addedExternalSubtitleIds = {}; // Track added subtitle IDs

  final List<BetterPlayerSubtitlesSource> _appliedSubtitles = [];
  ExternalSubtitleService? _subtitleService;
  List<BetterPlayerSubtitlesSource> get appliedSubtitles =>
      List.unmodifiable(_appliedSubtitles);

  BetterPlayerSubtitlesSource? get preferredCachedSubtitle =>
      _preferredRestoredSource;

  /// Restores subtitle files and labels before the initial BetterPlayer source
  /// is created. Cached video URLs and subtitle files have independent life
  /// cycles, so a stream-cache hit must not erase subtitle metadata.
  Future<void> restoreCachedSubtitles({
    required String mediaCacheKey,
    required String preferredLanguageCode,
    bool hasPreferredProviderSubtitle = false,
  }) async {
    if (_mediaCacheKey != mediaCacheKey) {
      _automaticPreferredSearchStarted = false;
      _availableExternalSubtitles = <ExternalSubtitle>[];
      _selectedExternalSubtitles.clear();
    }
    _mediaCacheKey = mediaCacheKey;
    _preferredLanguageCode = _normaliseLanguage(preferredLanguageCode);
    _preferredSubtitleRestored = false;
    _preferredRestoredSource = null;
    _appliedSubtitles.clear();
    _addedExternalSubtitleIds.clear();
    final cached = await _store.read(mediaCacheKey);
    var preferredAdded = hasPreferredProviderSubtitle;
    for (final track in cached) {
      final isPreferred = track.language == _preferredLanguageCode;
      final selectByDefault = isPreferred && !preferredAdded;
      final source = track.toPlayerSource(selectedByDefault: selectByDefault);
      _appliedSubtitles.add(source);
      _addedExternalSubtitleIds.add(track.id);
      if (selectByDefault) {
        preferredAdded = true;
        _preferredSubtitleRestored = true;
        _preferredRestoredSource = source;
      }
    }
    debugPrint(
      '[SubtitleCache][RESTORE] media=$mediaCacheKey '
      'tracks=${cached.length} preferred=${_preferredLanguageCode} '
      'preferredRestored=$_preferredSubtitleRestored',
    );
  }

  /// Searches the preferred language once after video setup and automatically
  /// applies the strongest matching external result. It never delays video
  /// startup and failures are isolated from playback.
  Future<void> ensurePreferredSubtitle({
    required BuildContext context,
    required String scraperApiUrl,
    required MediaType? mediaType,
    MovieStreamMetadata? movieMetadata,
    TVStreamMetadata? tvMetadata,
    required BetterPlayerController betterPlayerController,
    bool hasPreferredProviderSubtitle = false,
  }) async {
    if (hasPreferredProviderSubtitle) {
      _automaticPreferredSearchStarted = true;
      debugPrint('[SubtitleAuto][PROVIDER_TRACK_AVAILABLE] language=$_preferredLanguageCode');
      return;
    }
    if (_automaticPreferredSearchStarted ||
        _preferredSubtitleRestored ||
        _preferredLanguageCode.isEmpty ||
        _mediaCacheKey == null ||
        !context.mounted) {
      return;
    }
    _automaticPreferredSearchStarted = true;
    try {
      final service = ExternalSubtitleService(scraperApiUrl);
      _subtitleService = service;
      final results = await _searchForMedia(
        service: service,
        context: context,
        mediaType: mediaType,
        movieMetadata: movieMetadata,
        tvMetadata: tvMetadata,
      );
      if (!context.mounted) return;
      _availableExternalSubtitles = results;
      final preferred = results.where((item) =>
          _normaliseLanguage(item.language) == _preferredLanguageCode).toList();
      if (preferred.isEmpty) {
        debugPrint(
          '[SubtitleAuto][NO_PREFERRED_TRACK] language=$_preferredLanguageCode '
          'results=${results.length}',
        );
        return;
      }
      // Provider priority and release metadata are already reflected in the
      // merged search order. Try candidates in order until one downloads.
      for (final candidate in preferred.take(5)) {
        try {
          final source = await _downloadAndCache(candidate, service);
          if (!context.mounted) return;
          betterPlayerController.betterPlayerSubtitlesSourceList.add(source);
          _appliedSubtitles.add(source);
          _addedExternalSubtitleIds.add(candidate.id);
          await betterPlayerController.selectSubtitlesSource(source);
          _preferredSubtitleRestored = true;
          debugPrint(
            '[SubtitleAuto][APPLIED] language=$_preferredLanguageCode '
            'source=${candidate.source} id=${candidate.id}',
          );
          return;
        } catch (error) {
          debugPrint(
            '[SubtitleAuto][CANDIDATE_FAILED] source=${candidate.source} '
            'id=${candidate.id} error=$error',
          );
        }
      }
    } catch (error) {
      debugPrint('[SubtitleAuto][SEARCH_FAILED] $error');
    }
  }

  /// Show external subtitles menu
  void showExternalSubtitlesMenu({
    required BuildContext context,
    required List<Color> colors,
    required String scraperApiUrl,
    required MediaType? mediaType,
    MovieStreamMetadata? movieMetadata,
    TVStreamMetadata? tvMetadata,
    String? preferredLanguageCode,
    required BetterPlayerController betterPlayerController,
  }) {
    _preferredLanguageCode = _normaliseLanguage(
      preferredLanguageCode ?? _preferredLanguageCode,
    );
    _isExternalSubtitlesMenuOpen = true;
    _hasAutoLoadedExternalSubtitles = false;
    showPlayerSheet<void>(
      context: context,
      builder: (bottomSheetContext) => DraggableScrollableSheet(
        initialChildSize: .78,
        minChildSize: .52,
        maxChildSize: .95,
        expand: false,
        snap: true,
        snapSizes: const [.52, .78, .95],
        builder: (context, scrollController) => StatefulBuilder(
          builder: (context, setBottomSheetState) {
            // Load once per menu open. Guarding on "the list is empty" alone
            // would re-trigger this on every rebuild whenever the API
            // legitimately returns no subtitles, looping forever.
            if (_availableExternalSubtitles.isEmpty &&
                !_hasAutoLoadedExternalSubtitles) {
              _hasAutoLoadedExternalSubtitles = true;
              _isLoadingExternalSubtitles = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!context.mounted) return;
                _fetchExternalSubtitles(
                  setBottomSheetState,
                  context,
                  scraperApiUrl,
                  mediaType,
                  movieMetadata,
                  tvMetadata,
                  _preferredLanguageCode,
                );
              });
            }

            final Widget content;
            if (_isLoadingExternalSubtitles) {
              // The list of subtitles, pulsing, until it comes.
              content = const ListSkeleton(
                rows: 7,
                leadingWidth: 36,
                leadingHeight: 36,
                circle: true,
                scrolls: true,
              );
            } else if (_availableExternalSubtitles.isEmpty) {
              // Scrollable: on a short screen the empty state alone is taller
              // than the sheet, and a Column here would overflow.
              content = ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                children: [
                  const SizedBox(height: 8),
                  BetterPlayerEmptyState(
                    icon: PhosphorIcons.closedCaptioning(),
                    title: tr('no_external_subtitles_found'),
                    message: tr('try_searching_for_subtitles'),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: FilledButton.icon(
                      onPressed: () => _fetchExternalSubtitles(
                        setBottomSheetState,
                        context,
                        scraperApiUrl,
                        mediaType,
                        movieMetadata,
                        tvMetadata,
                        _preferredLanguageCode,
                      ),
                      icon: Icon(PhosphorIcons.magnifyingGlass()),
                      label: Text(tr('search_subtitles')),
                    ),
                  ),
                ],
              );
            } else {
              content = ListView.separated(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                itemCount: _availableExternalSubtitles.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder: (context, index) {
                  final subtitle = _availableExternalSubtitles[index];
                  final selected = _selectedExternalSubtitles
                      .any((item) => item.id == subtitle.id);
                  final details = <String>[
                    if (subtitle.isHearingImpaired) 'HI',
                    subtitle.format.toUpperCase(),
                    if (subtitle.source.trim().isNotEmpty) subtitle.source,
                    if (subtitle.release.isNotEmpty) subtitle.release,
                  ];
                  return PlayerChoiceCard(
                    title: languageDisplayName(subtitle.display),
                    subtitle: details.join('  •  '),
                    selected: selected,
                    onTap: () => _toggleExternalSubtitle(
                      subtitle,
                      setBottomSheetState,
                    ),
                    thumbnail: PlayerThumbnail(
                      width: 48,
                      height: 34,
                      child: subtitle.flagUrl.isEmpty
                          ? Icon(PhosphorIcons.flag())
                          : CachedNetworkImage(
                              imageUrl: subtitle.flagUrl,
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  const AppCachedImagePlaceholder(),
                              errorWidget: (_, __, ___) =>
                                  Icon(PhosphorIcons.flag()),
                            ),
                    ),
                  );
                },
              );
            }

            return PlayerSheetScaffold(
              title: tr('external_subtitles'),
              subtitle: _availableExternalSubtitles.isEmpty
                  ? tr('search_subtitles')
                  : tr(
                      'found_external_subtitles',
                      namedArgs: {
                        'count': '${_availableExternalSubtitles.length}',
                      },
                    ),
              actions: [
                if (_availableExternalSubtitles.isNotEmpty)
                  IconButton(
                    tooltip: tr('refresh'),
                    onPressed: _isLoadingExternalSubtitles
                        ? null
                        : () => _fetchExternalSubtitles(
                              setBottomSheetState,
                              context,
                              scraperApiUrl,
                              mediaType,
                              movieMetadata,
                              tvMetadata,
                              _preferredLanguageCode,
                            ),
                    icon: Icon(PhosphorIcons.arrowsClockwise()),
                  ),
                IconButton(
                  onPressed: () => Navigator.pop(bottomSheetContext),
                  icon: Icon(PhosphorIcons.x()),
                ),
              ],
              footer: _selectedExternalSubtitles.isEmpty
                  ? null
                  : PlayerSheetFooter(
                      label: tr(
                        'subtitles_selected',
                        namedArgs: {
                          'count': '${_selectedExternalSubtitles.length}',
                        },
                      ),
                      actionLabel: tr('apply'),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        Navigator.pop(bottomSheetContext);
                        await _applyExternalSubtitlesWithMessenger(
                          messenger,
                          betterPlayerController,
                        );
                      },
                    ),
              child: content,
            );
          },
        ),
      ),
    ).whenComplete(() {
      _isExternalSubtitlesMenuOpen = false;
    });
  }

  /// Search OpenSubtitles, SubSource, and the configured CineStream scraper.
  Future<void> _fetchExternalSubtitles(
    StateSetter setBottomSheetState,
    BuildContext context,
    String scraperApiUrl,
    MediaType? mediaType,
    MovieStreamMetadata? movieMetadata,
    TVStreamMetadata? tvMetadata,
    String preferredLanguageCode,
  ) async {
    _isLoadingExternalSubtitles = true;
    _setBottomSheetStateIfOpen(setBottomSheetState, () {
      _isLoadingExternalSubtitles = true;
    });

    try {
      final service = ExternalSubtitleService(scraperApiUrl);
      _subtitleService = service;
      final subtitles = await _searchForMedia(
        service: service,
        context: context,
        mediaType: mediaType,
        movieMetadata: movieMetadata,
        tvMetadata: tvMetadata,
        preferredLanguageCode: preferredLanguageCode,
      );

      _availableExternalSubtitles = subtitles;
      _isLoadingExternalSubtitles = false;
      _setBottomSheetStateIfOpen(setBottomSheetState, () {
        _availableExternalSubtitles = subtitles;
        _isLoadingExternalSubtitles = false;
      });

      // Show success message
      if (subtitles.isNotEmpty && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('found_external_subtitles',
                namedArgs: {'count': '${subtitles.length}'})),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      _isLoadingExternalSubtitles = false;
      _setBottomSheetStateIfOpen(setBottomSheetState, () {
        _isLoadingExternalSubtitles = false;
      });

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('failed_load_subtitles',
                namedArgs: {'error': e.toString()})),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<List<ExternalSubtitle>> _searchForMedia({
    required ExternalSubtitleService service,
    required BuildContext context,
    required MediaType? mediaType,
    MovieStreamMetadata? movieMetadata,
    TVStreamMetadata? tvMetadata,
    String? preferredLanguageCode,
  }) async {
    final preferred = _normaliseLanguage(
      preferredLanguageCode ?? _preferredLanguageCode,
    );
    if (mediaType == MediaType.movie) {
      final id = movieMetadata?.movieId;
      if (id == null || id <= 0) return const <ExternalSubtitle>[];
      return service.fetchMovieSubtitles(
        id,
        title: movieMetadata?.movieName,
        year: movieMetadata?.releaseYear,
        preferredLanguageCode: preferred,
      );
    }
    if (mediaType == MediaType.tvShow) {
      final id = tvMetadata?.tvId;
      final season = tvMetadata?.seasonNumber;
      final episode = tvMetadata?.episodeNumber;
      if (id == null || id <= 0 || season == null || episode == null) {
        return const <ExternalSubtitle>[];
      }
      return service.fetchTVSubtitles(
        id,
        season,
        episode,
        title: tvMetadata?.seriesName,
        year: _yearFromAirDate(tvMetadata?.airDate),
        preferredLanguageCode: preferred,
      );
    }
    return const <ExternalSubtitle>[];
  }

  String _normaliseLanguage(String? value) {
    final normalised = (value ?? '').trim().toLowerCase().split(RegExp(r'[-_]')).first;
    if (normalised == 'ara' || normalised == 'arabic') return 'ar';
    if (normalised == 'eng' || normalised == 'english') return 'en';
    return normalised;
  }

  Future<BetterPlayerSubtitlesSource> _downloadAndCache(
    ExternalSubtitle subtitle,
    ExternalSubtitleService service,
  ) async {
    final mediaKey = _mediaCacheKey;
    if (mediaKey == null || mediaKey.isEmpty) {
      throw StateError('Subtitle media cache key is not initialized.');
    }
    final normalised = await service.downloadAndNormalizeForPlayback(subtitle);
    final cached = await _store.save(
      mediaKey: mediaKey,
      subtitle: subtitle,
      webVtt: normalised,
    );
    return cached.toPlayerSource(
      selectedByDefault: _normaliseLanguage(subtitle.language) ==
          _preferredLanguageCode,
    );
  }

  int? _yearFromAirDate(String? airDate) {
    final value = airDate?.trim();
    if (value == null || value.length < 4) return null;
    return int.tryParse(value.substring(0, 4));
  }

  void _setBottomSheetStateIfOpen(
      StateSetter setBottomSheetState, VoidCallback fn) {
    if (!_isExternalSubtitlesMenuOpen) {
      return;
    }

    setBottomSheetState(fn);
  }

  /// Toggle selection of an external subtitle
  void _toggleExternalSubtitle(
      ExternalSubtitle subtitle, StateSetter setBottomSheetState) {
    final isSelected =
        _selectedExternalSubtitles.any((s) => s.id == subtitle.id);

    if (isSelected) {
      _selectedExternalSubtitles.removeWhere((s) => s.id == subtitle.id);
    } else {
      _selectedExternalSubtitles.add(subtitle);
    }

    setBottomSheetState(() {});
  }

  /// Apply selected external subtitles to the player
  Future<void> _applyExternalSubtitlesWithMessenger(
    ScaffoldMessengerState scaffoldMessenger,
    BetterPlayerController betterPlayerController,
  ) async {
    if (_selectedExternalSubtitles.isEmpty) return;

    final selected = List<ExternalSubtitle>.of(_selectedExternalSubtitles);
    scaffoldMessenger.showSnackBar(
      playerProgressSnackBar(
        message: tr(
          'downloading_processing_subtitles',
          namedArgs: {'count': '${selected.length}'},
        ),
      ),
    );

    var successCount = 0;
    var failedCount = 0;
    for (final externalSubtitle in selected) {
      if (_addedExternalSubtitleIds.contains(externalSubtitle.id)) continue;
      try {
        final service = _subtitleService ?? ExternalSubtitleService('');
        final betterPlayerSource = await _downloadAndCache(
          externalSubtitle,
          service,
        );
        betterPlayerController.betterPlayerSubtitlesSourceList
            .add(betterPlayerSource);
        _appliedSubtitles.add(betterPlayerSource);
        _addedExternalSubtitleIds.add(externalSubtitle.id);
        successCount++;
      } catch (error) {
        failedCount++;
        debugPrint(
          '[Subtitle][DOWNLOAD_FAILED] source=${externalSubtitle.source} '
          'language=${externalSubtitle.language} id=${externalSubtitle.id}: $error',
        );
      }
    }

    _selectedExternalSubtitles.clear();
    if (successCount > 0 && _appliedSubtitles.isNotEmpty) {
      try {
        await betterPlayerController.selectSubtitlesSource(_appliedSubtitles.last);
      } catch (error) {
        debugPrint('[Subtitle][SELECT_EXTERNAL_FAILED] $error');
      }
    }
    scaffoldMessenger.hideCurrentSnackBar();
    if (successCount > 0) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('added_external_subtitles',
                namedArgs: {'count': '$successCount'}) +
                (failedCount > 0 ? ' · $failedCount failed' : ''),
            style: const TextStyle(fontFamily: 'Figtree'),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } else if (failedCount > 0) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(tr(
            'failed_add_subtitles',
            namedArgs: {'error': '$failedCount subtitle(s) could not be downloaded'},
          )),
          duration: const Duration(seconds: 3),
        ),
      );
    } else {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(tr('all_subtitles_already_added')),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }
}
