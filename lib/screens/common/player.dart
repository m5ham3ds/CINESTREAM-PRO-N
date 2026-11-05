import 'package:flixquest/widgets/adsterra_playback_gate.dart';
import 'package:flixquest/data/ads/content_ads.dart';
import 'package:flixquest/models/adsterra_playback_ads_config.dart';
import 'package:flixquest/services/adsterra_playback_ads_service.dart';
import 'package:flixquest/widgets/playback_action.dart';
// ignore_for_file: deprecated_member_use

import 'dart:async';
import '../../data/sync/library_scope.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flixquest/models/tv_stream_metadata.dart';
import 'package:flixquest/models/wellness.dart';
import 'package:flixquest/provider/wellness_provider.dart';
import 'package:flixquest/models/offline_download.dart';

import '../../models/movie_stream_metadata.dart';
import '../../models/provider_video_source.dart';
import '../../video_providers/names.dart';
import '../../video_providers/provider_loader.dart';
import '../../video_providers/unified/media_identity.dart';
import '../../video_providers/common.dart';
import '../../video_providers/quality_catalog.dart';
import '../../video_providers/adaptive_quality_scanner.dart';
import '../../functions/video_utils.dart';
import '../../functions/network.dart';
import '../../functions/player_subtitle_configuration.dart';
import '../../functions/player_buffering_configuration.dart';
import '../../functions/language_names.dart';
import '../../functions/subtitle_options.dart';
import '/constants/app_constants.dart';
import '/widgets/common_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:provider/provider.dart';
import 'package:better_player_plus/better_player_plus.dart';
import '../../functions/function.dart';
import '../../provider/settings_provider.dart';
import '../../core/config/app_runtime.dart';
import '../../provider/offline_download_provider.dart';
import '../../provider/app_dependency_provider.dart';
import '../../constants/api_constants.dart';
import '../../api/endpoints.dart';
import '../../ui_components/app_ui_components.dart';
import '../../services/stream_intro_service.dart';
import '../../services/introdb_service.dart';
import '../../services/offline_download_service.dart';
import '../../services/playback_wake_lock.dart';
import '../../services/stream_size_estimator.dart';
import '../movie/movie_video_loader.dart';
import '../tv/tv_video_loader.dart';
import 'player/player_data_management.dart';
import 'player/player_background_save.dart';
import 'player/player_preroll_ad.dart';
import 'player/player_completion_detector.dart';
import 'player/tv_subtitle_timing_panel.dart';
import 'player/player_subtitle_timing_sheet.dart';
import 'player/player_external_subtitles.dart';
import 'player/player_local_subtitles.dart';
import 'player/player_episode_selection.dart';
import 'player/player_movie_recommendations.dart';
import 'player/player_next_episode_policy.dart';
import 'player/player_sheet_ui.dart';
import 'player/player_feedback_ui.dart';
import 'player/stream_feedback_prompt.dart';
import '../../services/stream_feedback_session.dart';
import '../../services/stream_feedback_service.dart';
import '../../services/automatic_stream_report.dart';
import '../../services/streaming_dnd_service.dart';
import '../../services/playback_stream_cache.dart';
import '../../widgets/ad_block_playback_guard.dart';
import '../../design/app_tokens.dart';
import 'player/player_watch_page.dart';
import 'player/player_strings.dart';
import 'download_selection_sheets.dart';

class PlayerOne extends StatefulWidget {
  const PlayerOne(
      {required this.sources,
      required this.subs,
      required this.colors,
      required this.settings,
      this.movieMetadata,
      this.tvMetadata,
      required this.mediaType,
      required this.subtitleStyle,
      this.onEpisodeChange, // Callback for when user selects a different episode
      this.availableProviders, // Provider metadata for lazy loading
      this.currentProviderCode, // Current provider code
      this.initialPlaybackPosition, // For preserving position on provider switch
      this.scraperApiUrl = '',
      this.videoFormats,
      this.videoHeaders = const {},
      this.videoSizeTokens = const {},
      this.initialVideoLinks = const [],
      this.initialSubtitleLinks = const [],
      this.providerScanSession,
      this.cachedProviderResults = const <String, ProviderLoadResult>{},
      this.initialStreamUrl,
      this.useTvControls = false,
      this.onTvPlayerExit,
      super.key});
  final Map<String, String> sources;
  final List<BetterPlayerSubtitlesSource> subs;
  final List<Color> colors;
  final SettingsProvider settings;
  final MovieStreamMetadata? movieMetadata;
  final TVStreamMetadata? tvMetadata;
  final MediaType? mediaType;
  final String? subtitleStyle;
  final Function(int episodeId, int episodeNumber, int seasonNumber)?
      onEpisodeChange;
  final List<VideoProvider>?
      availableProviders; // Changed to VideoProvider list
  final String? currentProviderCode;
  final Duration? initialPlaybackPosition;
  final String scraperApiUrl;
  final Map<String, BetterPlayerVideoFormat?>? videoFormats;
  final Map<String, Map<String, String>> videoHeaders;
  final Map<String, String> videoSizeTokens;
  final List<RegularVideoLinks> initialVideoLinks;
  final List<RegularSubtitleLinks> initialSubtitleLinks;
  final ProviderScanSession? providerScanSession;
  final Map<String, ProviderLoadResult> cachedProviderResults;
  final String? initialStreamUrl;
  final bool useTvControls;
  final VoidCallback? onTvPlayerExit;

  @override
  State<PlayerOne> createState() => _PlayerOneState();
}

class _PlayerOneState extends State<PlayerOne> with WidgetsBindingObserver {
  late final StreamingDndSession _streamingDnd;
  late BetterPlayerController _betterPlayerController;
  bool _betterPlayerControllerInitialized = false;
  final StreamIntroService _introService = StreamIntroService();
  final IntroDbService _introDbService = IntroDbService();
  final BetterPlayerTvControlsController _tvControlsController =
      BetterPlayerTvControlsController();
  late BetterPlayerControlsConfiguration betterPlayerControlsConfiguration;
  late BetterPlayerBufferingConfiguration betterPlayerBufferingConfiguration;
  final PlayerDataManagement _dataManagement = PlayerDataManagement();
  final PlayerExternalSubtitles _externalSubtitles = PlayerExternalSubtitles();
  final PlayerLocalSubtitles _localSubtitles = PlayerLocalSubtitles();
  late final PlayerEpisodeSelection _episodeSelection;
  final PlayerMovieRecommendations _movieRecommendations =
      PlayerMovieRecommendations();
  late final List<EpisodeMetadata> _contentMenuEpisodes;
  late final List<SeasonMetadata> _contentMenuSeasons;
  int duration = 0;
  final _feedbackSession = StreamFeedbackSession();
  final _automaticStreamReport = AutomaticStreamReport();
  final _feedbackConnection = StreamFeedbackConnection();
  bool _exitingPlayer = false;
  bool _adBlockStopped = false;
  String _automaticReportEndReason = 'route_disposed';
  int _feedbackSourceSwitches = 0;

  final GlobalKey _betterPlayerKey = GlobalKey();

  int totalMinutesWatched = 0;
  bool isVideoPaused = false;

  int playbackDurationInSeconds = 0;
  Timer? _durationTimer;
  // ignore: unused_field
  Timer? _resetTimer;

  // For next episode button
  bool _showNextEpisodeButton = false;
  bool _nextEpisodeButtonDismissed = false;
  bool _preRollActive = false;

  /// The video ad playing as the pre-roll, if any. Its timeline is separate
  /// from the content's: progress, subtitles and resume points ignore it.
  late final PlayerPrerollAd _prerollAd =
      PlayerPrerollAd(television: widget.useTvControls);

  /// A recently-watched save requested during the pre-roll, when the player's
  /// position belongs to the ad. It runs once the content starts.
  bool _recentInsertPending = false;

  /// Between the end of a pre-roll and the content's own initialized event.
  /// The content's duration is unknown until then; nothing may measure the
  /// content's position against a duration in the meantime.
  bool _awaitingContentAfterPreRoll = false;
  IntroDbTimings _introDbTimings = IntroDbTimings.empty;
  IntroDbSegment? _activeIntroDbSegment;
  final Set<String> _skippedIntroDbSegments = <String>{};
  bool _introDbLoading = false;
  bool _introDbCreditsActive = false;
  int _introDbRequestId = 0;
  bool _introDbLookupComplete = false;
  bool _introDbLookupSettled = false;
  bool _playbackCompletionHandled = false;
  final PlayerCompletionDetector _completionDetector = PlayerCompletionDetector(
    stalledEndTolerance: const Duration(seconds: 12),
    requiredStableSamples: 3,
  );
  Timer? _progressCheckTimer;
  OverlayEntry? _nextEpisodeOverlay;

  /// The phone's next-episode card: which episode it offers, and the count
  /// once the episode has ended (null while it is only a teaser).
  EpisodeMetadata? _phoneNextEpisode;
  int? _phoneNextEpisodeCountdown;
  Timer? _phoneNextEpisodeTimer;
  bool _playerControlsVisible = false;

  /// Picture in Picture shows the video alone, so the next-episode card
  /// steps aside while it is open.
  bool _inPictureInPicture = false;
  String? _lastNextEpisodeDebugSignature;
  Timer? _tvNextEpisodeTimer;
  EpisodeMetadata? _tvNextEpisode;
  int? _tvNextEpisodeCountdown;
  int _tvNextEpisodeCountdownTotal = 10;

  /// The prompt came up at the credits rather than the end, so declining it
  /// means watching them.
  bool _tvNextEpisodeAtCredits = false;
  _TvPlayerMenuData? _tvMenu;
  bool _tvSubtitleTimingOpen = false;
  int? _portraitBrowsedSeasonNumber;
  bool _portraitSeasonLoading = false;
  bool _startingContent = false;
  OverlayEntry? _contentSwitchLoading;
  Orientation? _lastScreenOrientation;
  bool _landscapeFullscreenRequestPending = false;

  late SettingsProvider settings;

  // Provider switching
  bool _isSwitchingProvider = false;
  late String? _currentProviderCode; // Track current provider
  final Map<String, ProviderVideoSource> _loadedProviders =
      {}; // Cache loaded providers
  final Map<String, Future<ProviderLoaderResult>> _providerResults = {};
  final Map<String, List<RegularVideoLinks>> _rawVideoLinksByProvider = {};
  final Map<String, List<RegularSubtitleLinks>> _subtitleLinksByProvider = {};
  final ValueNotifier<int> _streamCatalogRevision = ValueNotifier<int>(0);
  final PlaybackStreamCacheStore _playbackCache = PlaybackStreamCacheStore();
  final AdaptiveQualityScanner _adaptiveQualityScanner =
      AdaptiveQualityScanner();
  final Set<String> _adaptiveQualityScansStarted = <String>{};
  final Set<String> _adaptiveQualityScansInProgress = <String>{};
  StreamSubscription<ProviderScanUpdate>? _providerScanSubscription;
  String? _initialSelectedResolutionKey;
  bool _hasPlaybackInitialized = false;
  bool _cacheWriteInProgress = false;
  bool _cacheWritePending = false;
  String? _activeStreamUrl;
  String? _activeStreamServerName;
  final Map<String, Set<String>> _failedStreamUrlsByProvider =
      <String, Set<String>>{};
  final Map<String, Set<String>> _refreshedStreamUrlsByProvider =
      <String, Set<String>>{};
  final Set<String> _exhaustedProviderCodes = <String>{};
  late Map<String, String> _activeSources;
  late List<BetterPlayerSubtitlesSource> _activeSubtitles;
  late Map<String, BetterPlayerVideoFormat?>? _activeVideoFormats;
  late Map<String, Map<String, String>> _activeVideoHeaders;
  late Map<String, String> _activeVideoSizeTokens;
  final Map<String, int?> _streamSizeCacheByToken = {};
  final Set<String> _loadingProviders =
      {}; // Track which providers are being loaded
  final Map<String, String> _providerErrors = {};
  DateTime? _startupPlaybackWatchStartedAt;
  bool _startupTimeoutLogged = false;
  late final DateTime _analyticsSessionStartedAt;
  late final String _analyticsSessionId;
  late final WellnessPlaybackTracker _wellnessTracker;
  DateTime? _lastWellnessCheckpointAt;
  DateTime? _analyticsPlayingStartedAt;
  DateTime? _analyticsBufferingStartedAt;
  int _analyticsWatchedMs = 0;
  int _analyticsBufferingMs = 0;
  int _analyticsBufferCount = 0;
  int _analyticsProviderSwitchCount = 0;
  int _analyticsInitializationCount = 0;
  bool _analyticsWasPlayingBeforeBuffering = false;
  String? _lastAnalyticsError;
  DateTime? _lastAnalyticsErrorAt;
  late final AppDependencyProvider _appDependencies;
  int? _occasionalEffectsSuppressionId;
  bool _isContentMenuOpen = false;

  @override
  void initState() {
    _feedbackConnection.start();
    settings = Provider.of<SettingsProvider>(context, listen: false);
    _streamingDnd =
        StreamingDndSession(settings, television: widget.useTvControls);
    _currentProviderCode = widget.currentProviderCode; // Initialize from widget
    _activeSources = Map.of(widget.sources);
    _activeSubtitles = List.of(widget.subs);
    _activeVideoFormats =
        widget.videoFormats == null ? null : Map.of(widget.videoFormats!);
    _activeVideoHeaders = Map.of(widget.videoHeaders);
    _activeVideoSizeTokens = Map.of(widget.videoSizeTokens);
    final initialProviderCode = widget.currentProviderCode;
    if (initialProviderCode != null && widget.initialVideoLinks.isNotEmpty) {
      final initialLinks = widget.initialVideoLinks
          .map((link) => link.copyWith(providerCode: initialProviderCode))
          .toList(growable: false);
      _rawVideoLinksByProvider[initialProviderCode] = initialLinks;
      _subtitleLinksByProvider[initialProviderCode] =
          List<RegularSubtitleLinks>.of(widget.initialSubtitleLinks);
      _mergeAggregateLinks(initialLinks);
      final exactUrl = widget.initialStreamUrl?.trim();
      final MapEntry<String, String>? selected = exactUrl == null || exactUrl.isEmpty
          ? VideoUtils.preferredVideoSource(
              _activeSources,
              settings.defaultVideoResolution,
            )
          : _activeSources.entries
              .where((entry) => entry.value == exactUrl)
              .map((entry) => MapEntry(entry.key, entry.value))
              .firstOrNull;
      if (selected != null) {
        _initialSelectedResolutionKey = selected.key;
        _activeStreamUrl = selected.value;
        _activeStreamServerName = _serverNameForUrl(
          selected.value,
          providerCode: initialProviderCode,
        );
      }
    }
    final scanSnapshot = widget.providerScanSession?.resolvedResults ??
        const <String, ProviderLoadResult>{};
    final startupProviderResults = <String, ProviderLoadResult>{
      ...widget.cachedProviderResults,
      ...scanSnapshot,
    };
    for (final entry in startupProviderResults.entries) {
      final providerCode = entry.key;
      final provider = (widget.availableProviders ?? const <VideoProvider>[])
          .where((candidate) => candidate.codeName == providerCode)
          .firstOrNull;
      if (provider == null) continue;
      final result = entry.value;
      final links = (result.videoLinks ?? const <RegularVideoLinks>[])
          .map((link) => link.copyWith(
                providerCode: providerCode,
                server: link.server?.trim().isNotEmpty == true
                    ? link.server
                    : provider.displayName,
              ))
          .toList(growable: false);
      if (links.isEmpty) continue;
      _rawVideoLinksByProvider[providerCode] = links;
      _subtitleLinksByProvider[providerCode] =
          List<RegularSubtitleLinks>.of(result.subtitleLinks ?? const []);
      final cachedResult = ProviderLoadResult(
        success: true,
        videoLinks: links,
        subtitleLinks: result.subtitleLinks,
      );
      _providerResults[providerCode] =
          Future<ProviderLoaderResult>.value(cachedResult);
      _loadedProviders[providerCode] = _providerSourceFromResult(
        provider: provider,
        result: cachedResult,
      );
      _mergeAggregateLinks(links);
    }
    final scanSession = widget.providerScanSession;
    _providerScanSubscription = scanSession?.updates.listen(
      _handleProviderScanUpdate,
    );
    if (scanSession != null) {
      unawaited(scanSession.completed.then((_) {
        if (!mounted) return;
        _notifyStreamCatalogChanged();
        setState(() {});
      }));
    }
    if (widget.mediaType == MediaType.movie) {
      final metadata = widget.movieMetadata;
      final recommendations = metadata?.recommendations;
      debugPrint(
        '[MovieRecommendationsDebug][PLAYER_INIT] '
        'movieId=${metadata?.movieId} '
        'title=${metadata?.movieName} '
        'metadataCount=${recommendations?.length ?? 0} '
        'ids=${recommendations?.map((movie) => movie.movieId).join(',') ?? ''}',
      );
    }
    _contentMenuEpisodes = List<EpisodeMetadata>.of(
      widget.tvMetadata?.seasonEpisodes ?? const <EpisodeMetadata>[],
    );
    _contentMenuSeasons = List<SeasonMetadata>.of(
      widget.tvMetadata?.allSeasons ?? const <SeasonMetadata>[],
    );
    super.initState();
    _appDependencies =
        Provider.of<AppDependencyProvider>(context, listen: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _occasionalEffectsSuppressionId != null) return;
      _occasionalEffectsSuppressionId =
          _appDependencies.suppressOccasionalEffects();
    });
    _analyticsSessionStartedAt = DateTime.now();
    _analyticsSessionId =
        '${_analyticsSessionStartedAt.microsecondsSinceEpoch}-${identityHashCode(this)}';
    _wellnessTracker = WellnessPlaybackTracker(
      id: _analyticsSessionId,
      createdAt: _analyticsSessionStartedAt,
      libraryGeneration: LibraryScope.generation,
    );

    // Initialize episode selection with current season
    _episodeSelection = PlayerEpisodeSelection(widget.tvMetadata?.seasonNumber);

    WidgetsBinding.instance.addObserver(this);
    // Playback owns the screen for the whole session on both surfaces. Held
    // per player, so this one being disposed after a replacement (the next
    // episode) has started cannot clear the replacement's hold.
    PlaybackWakeLock.instance.hold(this);
    betterPlayerBufferingConfiguration = buildPlayerBufferingConfiguration(
      maximumDurationMs: widget.settings.defaultMaxBufferDuration,
      television: widget.useTvControls,
    );
    final hasEpisodeSelection =
        widget.mediaType == MediaType.tvShow && _contentMenuEpisodes.isNotEmpty;
    final hasMovieRecommendations = widget.mediaType == MediaType.movie &&
        (widget.movieMetadata?.recommendations?.isNotEmpty ?? false);
    debugPrint(
      '[PlayerContentMenu] configure '
      'mediaType=${widget.mediaType} '
      'useTvControls=${widget.useTvControls} '
      'episodes=${widget.tvMetadata?.seasonEpisodes?.length ?? 0} '
      'recommendations=${widget.movieMetadata?.recommendations?.length ?? 0} '
      'episodeButton=$hasEpisodeSelection '
      'recommendationsButton=$hasMovieRecommendations',
    );
    final controlsStrings = playerControlsStrings();
    betterPlayerControlsConfiguration = BetterPlayerControlsConfiguration(
        // Gesture controls configuration
        gestureConfiguration: BetterPlayerGestureConfiguration(
          enableVolumeSwipe: !widget.useTvControls,
          enableBrightnessSwipe: !widget.useTvControls,
          enableSeekSwipe: !widget.useTvControls,
          enableDoubleTapSeek: !widget.useTvControls,
          volumeSwipeSensitivity: 0.5,
          brightnessSwipeSensitivity: 0.5,
          seekSwipeSensitivity: 1.0,
        ),
        onFullScreenChange: _saveRecentProgress,
        enableFullscreen: true,
        // Handheld actions are supplied through quickActions below to keep
        // the exact FlixQuest order. TV keeps the native episode selector.
        enableEpisodeSelection: widget.useTvControls && hasEpisodeSelection,
        // Open immediately: addPostFrameCallback does not request a frame and
        // can leave these controls unresponsive while playback is idle.
        onEpisodeListTap: () {
          debugPrint('[PlayerContentMenu] episodes control tapped');
          unawaited(_openEpisodeList());
        },
        enableMovieRecommendations:
            widget.useTvControls && hasMovieRecommendations,
        onMovieRecommendationsTap: () {
          debugPrint('[PlayerContentMenu] recommendations control tapped');
          unawaited(_openMovieRecommendations());
        },
        enableNextEpisodeButton: widget.mediaType == MediaType.tvShow &&
            widget.settings.enableNextEpisodeButton,
        introDbSkipButtonBuilder: _buildIntroDbSkipButton,
        preRollOverlayBuilder: _buildPrerollOverlay,
        introDbSkipAvailable: _canSkipIntroDbSegment,
        onIntroDbSkip: _skipActiveIntroDbSegment,
        // The native MediaRouteButton currently crashes on some Android
        // devices when its platform-view background resolves to transparent.
        enableCast: false,
        name: widget.mediaType == MediaType.movie
            ? widget.movieMetadata!.movieName!
            : widget.tvMetadata!.seriesName!,
        subtitle: widget.mediaType == MediaType.movie
            ? widget.movieMetadata!.releaseYear?.toString()
            : 'S${widget.tvMetadata!.seasonNumber}:E${widget.tvMetadata!.episodeNumber} · ${widget.tvMetadata!.episodeName ?? ''}',
        strings: controlsStrings,
        languageLabelBuilder: languageDisplayName,
        emphasisFontFamily: 'FigtreeSB',
        onNextEpisodeTap: widget.useTvControls ||
                widget.mediaType != MediaType.tvShow ||
                !_hasNextEpisode()
            ? null
            : () => unawaited(_playNextEpisodeFromControls()),
        backgroundColor: Colors.black,
        progressBarBackgroundColor: Colors.white24,
        progressBarHandleColor: widget.colors.first,
        controlBarColor: Colors.black.withValues(alpha: 0.48),
        muteIcon: PhosphorIcons.speakerSimpleSlash(),
        unMuteIcon: PhosphorIcons.speakerHigh(),
        pauseIcon: PhosphorIcons.pause(PhosphorIconsStyle.fill),
        pipMenuIcon: PhosphorIcons.pictureInpicture(),
        playIcon: PhosphorIcons.play(PhosphorIconsStyle.fill),
        showControlsOnInitialize: widget.useTvControls,
        controlsHideTime: widget.useTvControls
            ? const Duration(seconds: 4)
            : const Duration(milliseconds: 300),
        // Match FlixQuest's default surface-based control selection: every
        // content type uses the native custom TV controls on the TV surface.
        // Movie/episode differences stay in the action callbacks and data
        // bridge, not in a separate visual player implementation.
        playerTheme: widget.useTvControls ? BetterPlayerTheme.custom : null,
        customControlsBuilder: widget.useTvControls
            ? (controller, onVisibilityChanged) => BetterPlayerTvControls(
                  controller: controller,
                  controlsController: _tvControlsController,
                  onControlsVisibilityChanged: onVisibilityChanged,
                  accentColor: widget.colors.first,
                  onExit: _exitPlayer,
                )
            : null,
        // Only the timeline's played part carries the brand colour.
        loadingColor: Colors.white,
        iconsColor: Colors.white,
        backwardSkipTimeInMilliseconds:
            Duration(seconds: widget.settings.defaultSeekDuration)
                .inMilliseconds,
        forwardSkipTimeInMilliseconds:
            Duration(seconds: widget.settings.defaultSeekDuration)
                .inMilliseconds,
        progressBarPlayedColor: widget.colors.first,
        progressBarBufferedColor: Colors.white38,
        skipForwardIcon: PhosphorIcons.arrowClockwise(),
        skipBackIcon: PhosphorIcons.arrowCounterClockwise(),
        fullscreenEnableIcon: PhosphorIcons.cornersOut(),
        fullscreenDisableIcon: PhosphorIcons.cornersIn(),
        overflowMenuIcon: PhosphorIcons.dotsThreeVertical(),
        subtitlesIcon: PhosphorIcons.closedCaptioning(),
        // FlixQuest's handheld row owns Audio & Subtitles and HD as dedicated
        // actions. CineStream routes these actions into its existing subtitle
        // and all-provider quality bridges through quickActions below.
        // Disabling their native overflow entries keeps the wide More panel at
        // the three FlixQuest defaults: speed, crop/fit, and download.
        enableSubtitles: widget.useTvControls,
        showSubtitlesButton: false,
        onSubtitlesTap: null,
        qualitiesIcon: PhosphorIcons.highDefinition(),
        enableQualities:
            widget.useTvControls && widget.mediaType != MediaType.movie,
        showQualitiesButton: false,
        enableDownloadButton: !widget.useTvControls,
        onDownloadTap:
            widget.useTvControls ? null : _downloadFromCurrentProvider,
        enableCrop: true,
        cropIcon: PhosphorIcons.crop(),
        enableAudioTracks: true,
        controlBarHeight: 56,
        watchingText: tr('watching_text'),
        playerTimeMode: settings.playerTimeDisplay,
        // A source that won't play is fixed from the controls, not a menu
        // away: Switch Provider sits with the other playback actions.
        quickActions: [
          if (widget.availableProviders?.isNotEmpty == true ||
              widget.useTvControls)
            BetterPlayerOverflowMenuItem(
              PhosphorIcons.hardDrives(),
              tr('switch_provider'),
              widget.useTvControls
                  ? _showTvProviderMenu
                  : _showProviderSwitcher,
            ),
          // Use BetterPlayer's existing action-row renderer, in FlixQuest's
          // exact order, while keeping CineStream's original callbacks.
          if (!widget.useTvControls &&
              widget.mediaType == MediaType.movie &&
              hasMovieRecommendations)
            BetterPlayerOverflowMenuItem(
              PhosphorIcons.squaresFour(),
              controlsStrings.moreLikeThis,
              () => unawaited(_openMovieRecommendations()),
            ),
          if (!widget.useTvControls &&
              widget.mediaType == MediaType.tvShow &&
              hasEpisodeSelection)
            BetterPlayerOverflowMenuItem(
              PhosphorIcons.cardsThree(),
              controlsStrings.episodes,
              () => unawaited(_openEpisodeList()),
            ),
          if (!widget.useTvControls)
            BetterPlayerOverflowMenuItem(
              PhosphorIcons.closedCaptioning(),
              controlsStrings.audioAndSubtitles,
              _showSubtitleSwitcher,
            ),
          if (!widget.useTvControls)
            BetterPlayerOverflowMenuItem(
              PhosphorIcons.highDefinition(),
              controlsStrings.quality,
              _showQualitySwitcher,
            ),
        ],
        // Handheld More mirrors the three default FlixQuest entries. The HD
        // action above routes to CineStream's unified all-provider catalog;
        // external-player access remains on the portrait watch page. TV keeps
        // its own remote-friendly quality, subtitle timing, and upload items.
        overflowMenuCustomItems: widget.useTvControls
            ? [
                BetterPlayerOverflowMenuItem(
                  PhosphorIcons.highDefinition(),
                  tr('player_quality'),
                  _showTvQualityMenu,
                ),
                BetterPlayerOverflowMenuItem(
                  PhosphorIcons.timer(),
                  tr('subtitle_timing'),
                  _showTvSubtitleTiming,
                ),
                BetterPlayerOverflowMenuItem(
                  PhosphorIcons.fileArrowUp(),
                  tr('upload_subtitles'),
                  () {
                    _localSubtitles.showLocalSubtitlesUpload(
                      context: context,
                      colors: widget.colors,
                      betterPlayerController: _betterPlayerController,
                    );
                  },
                ),
              ]
            : const [],
    );

    BetterPlayerConfiguration betterPlayerConfiguration =
        BetterPlayerConfiguration(
            autoDetectFullscreenDeviceOrientation: !widget.useTvControls,
            fullScreenByDefault:
                widget.useTvControls ? false : widget.settings.defaultViewMode,
            autoPlay: true,
            fit: BoxFit.contain,
            // Ambient glow continuously samples the video frame and is costly
            // on TV GPUs. Keep the existing effect for mobile playback.
            enableAmbientGlow: !widget.useTvControls,
            autoDispose: true,
            controlsConfiguration: betterPlayerControlsConfiguration,
            showPlaceholderUntilPlay: true,
            // PlaybackWakeLock keeps the screen on for the whole session.
            // Better Player's own hold covers only its fullscreen route and
            // clears the flag on the way out, under whatever else needs it.
            allowedScreenSleep: true,
            autoDetectFullscreenAspectRatio: !widget.useTvControls,
            errorBuilder: (context, _) =>
                _buildCustomPlayerErrorWidget(context),
            // Provider links expire mid-movie; resolve the provider again
            // before the player gives up and shows the error.
            sourceRecoveryHandler: _refreshCurrentProviderSource,
            subtitlesConfiguration: buildPlayerSubtitleConfiguration(
              backgroundColor: widget.settings.subtitleBackgroundColor,
              foregroundColor: widget.settings.subtitleForegroundColor,
              fontSize: widget.settings.subtitleFontSize,
              textStyle:
                  widget.subtitleStyle ?? widget.settings.subtitleTextStyle,
            ));

    // The data source is built inside _setupInitialDataSource after cached
    // external subtitle tracks have been restored. This keeps subtitle names
    // and the user's preferred Arabic track when a cached video URL is reused.
    _betterPlayerController = BetterPlayerController(betterPlayerConfiguration);
    _betterPlayerControllerInitialized = true;
    if (widget.mediaType == MediaType.tvShow) {
      _logNextEpisodeState('player_init', force: true);
    }
    settings.addListener(_syncAmbientGlowSetting);
    _syncAmbientGlowSetting();
    settings.addListener(_syncAutoPipSetting);
    _syncAutoPipSetting();
    _betterPlayerController.setBetterPlayerGlobalKey(_betterPlayerKey);
    _betterPlayerController.addEventsListener(_onAnalyticsPlayerEvent);
    unawaited(_scanAdaptiveQualityLinks(
      _rawVideoLinksByProvider.values.expand((items) => items).toList(),
    ));
    // Attach listeners before setup so native initialization and pre-roll
    // transition events cannot race the first platform callback.
    unawaited(_setupInitialDataSource());

    // Monitor every stream because some platform/provider combinations reach
    // the final timestamp without delivering Better Player's finished event.
    _startPlaybackMonitor();

    // _betterPlayerController.addEventsListener((BetterPlayerEvent event) {
    //   if (event.betterPlayerEventType == BetterPlayerEventType.play ||
    //       event.betterPlayerEventType == BetterPlayerEventType.bufferingEnd) {
    //     startDurationTimer();
    //   } else if (event.betterPlayerEventType == BetterPlayerEventType.pause ||
    //       event.betterPlayerEventType == BetterPlayerEventType.bufferingStart) {
    //     pauseDurationTimer();
    //   } else if (event.betterPlayerEventType ==
    //       BetterPlayerEventType.finished) {
    //     resetDurationTimer();
    //   }
    // });
  }

  String _resolveScraperApiUrl() {
    if (widget.scraperApiUrl.trim().isNotEmpty) {
      return widget.scraperApiUrl.trim();
    }
    return Provider.of<AppDependencyProvider>(context, listen: false)
        .flixquestAPIURL;
  }

  String get _subtitlePlaybackKey {
    if (widget.mediaType == MediaType.movie) {
      final id = widget.movieMetadata?.movieId ?? 0;
      return 'movie_$id';
    }
    final metadata = widget.tvMetadata;
    return 'tv_${metadata?.tvId ?? 0}_s${metadata?.seasonNumber ?? 0}_e${metadata?.episodeNumber ?? 0}';
  }

  String _normaliseSubtitleLanguage(String? value) {
    final language = (value ?? '').trim().toLowerCase();
    if (language.isEmpty) return '';
    final first = language.split(RegExp(r'[-_\s·\[]')).first;
    if (first == 'ara' || first == 'arabic') return 'ar';
    if (first == 'eng' || first == 'english') return 'en';
    return first;
  }

  bool _hasPreferredProviderSubtitle(String languageCode) {
    final preferred = _normaliseSubtitleLanguage(languageCode);
    if (preferred.isEmpty) return false;
    return _activeSubtitles.any((source) =>
        source.selectedByDefault == true &&
        _normaliseSubtitleLanguage(source.name) == preferred);
  }

  Future<void> _ensurePreferredExternalSubtitle() async {
    if (!mounted || _preRollActive || !_betterPlayerControllerInitialized) return;
    await _externalSubtitles.ensurePreferredSubtitle(
      context: context,
      scraperApiUrl: _resolveScraperApiUrl(),
      mediaType: widget.mediaType,
      movieMetadata: widget.movieMetadata,
      tvMetadata: widget.tvMetadata,
      betterPlayerController: _betterPlayerController,
      hasPreferredProviderSubtitle:
          _hasPreferredProviderSubtitle(settings.defaultSubtitleLanguage),
    );
  }

  void _syncAmbientGlowSetting() {
    _betterPlayerController.setAmbientGlowEnabled(
      !widget.useTvControls && settings.playerAmbientGlowEnabled,
    );
  }

  // Leaving the app (home button) moves a playing video into picture in
  // picture, whether or not the player is full screen.
  void _syncAutoPipSetting() {
    unawaited(
      _betterPlayerController.setAutoPictureInPicture(
        !widget.useTvControls && settings.autoPipOnLeave,
      ),
    );
  }

  Future<void> _setupInitialDataSource() async {
    try {
      await _externalSubtitles.restoreCachedSubtitles(
        mediaCacheKey: _subtitlePlaybackKey,
        preferredLanguageCode: settings.defaultSubtitleLanguage,
        hasPreferredProviderSubtitle:
            _hasPreferredProviderSubtitle(settings.defaultSubtitleLanguage),
      );
    } catch (error) {
      // Subtitle cache recovery is optional and must never block video start.
      debugPrint('[SubtitleCache][RESTORE_ERROR] $error');
    }
    if (!mounted || _adBlockStopped) return;
    final dataSource = _buildDataSource(
      sources: _activeSources,
      subtitles: _activeSubtitles,
      videoFormats: _activeVideoFormats,
      videoHeaders: _activeVideoHeaders,
      selectedResolution: _initialSelectedResolutionKey,
    );
    final metadataElapsed = widget.mediaType == MediaType.movie
        ? widget.movieMetadata?.elapsed
        : widget.tvMetadata?.elapsed;
    final requestedPosition = widget.initialPlaybackPosition ??
        Duration(seconds: metadataElapsed ?? 0);
    final initialPosition =
        requestedPosition < Duration.zero ? Duration.zero : requestedPosition;
    try {
      // The ad request runs alongside the intro lookup; neither waits on the
      // other, and a missing ad never delays the content.
      final adFuture = AppRuntime.localDevelopment
          ? Future.value(null)
          : _prerollAd.load(_appDependencies.vastPreroll,
              cancelled: () => !mounted || _adBlockStopped,
              adFreeContent: ContentAdScope.adFreeAt(context));
      StreamIntroConfig intro = const StreamIntroConfig.disabled();
      if (!AppRuntime.localDevelopment) {
        try {
          intro = await _introService.fetch(_resolveScraperApiUrl());
        } catch (error) {
          debugPrint('[Player] Branded intro unavailable: $error');
        }
      }
      final prerollAd = await adFuture;
      if (!mounted || _adBlockStopped) return;

      if (prerollAd != null) {
        // The ad replaces the branded intro for this session: one pre-roll
        // keeps the wait before the content short.
        _preRollActive = true;
        _prerollAd.start(prerollAd, _betterPlayerController);
        await _betterPlayerController.setupDataSourceWithPreRoll(
          preRollDataSource: PlayerPrerollAd.dataSource(prerollAd.media),
          betterPlayerDataSource: dataSource,
          contentStartPosition: initialPosition,
        );
      } else if (intro.enabled && intro.url != null) {
        _preRollActive = true;
        await _betterPlayerController.setupDataSourceWithPreRoll(
          preRollDataSource: _buildIntroDataSource(intro.url!),
          betterPlayerDataSource: dataSource,
          contentStartPosition: initialPosition,
        );
      } else {
        _preRollActive = false;
        _startupPlaybackWatchStartedAt = DateTime.now();
        _startupTimeoutLogged = false;
        await _betterPlayerController.setupDataSource(
          dataSource,
          initialPosition: initialPosition,
        );
      }
      if (!mounted || _adBlockStopped) return;
      final restoredPreferredSubtitle =
          _externalSubtitles.preferredCachedSubtitle;
      if (restoredPreferredSubtitle != null) {
        try {
          await _betterPlayerController
              .selectSubtitlesSource(restoredPreferredSubtitle);
        } catch (error) {
          debugPrint('[SubtitleCache][SELECT_RESTORED_FAILED] $error');
        }
      }
      _applyPreferredAdaptiveQuality();
      duration = _betterPlayerController
              .videoPlayerController?.value.duration?.inSeconds ??
          0;
      debugPrint(
        '[Player][IntroDB] initial data source ready '
        'durationSeconds=$duration preRoll=$_preRollActive',
      );
      if (!_preRollActive) {
        unawaited(_loadIntroDbTimings());
        unawaited(_ensurePreferredExternalSubtitle());
      }
    } catch (error) {
      if (_adBlockStopped) return;
      _preRollActive = false;
      _prerollAd.finish('error');
      _feedbackSession.recordFailure();
      debugPrint('[Player] Initial stream setup failed: $error');
    }
  }

  Widget? _buildPrerollOverlay(
    BuildContext context,
    BetterPlayerController controller,
  ) =>
      _prerollAd.overlay(context, onExit: _exitPlayer);

  BetterPlayerDataSource _buildIntroDataSource(Uri url) {
    return BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      url.toString(),
      cacheConfiguration: const BetterPlayerCacheConfiguration(
        useCache: true,
        maxCacheSize: 50 * 1024 * 1024,
        maxCacheFileSize: 20 * 1024 * 1024,
      ),
    );
  }

  String get _analyticsMediaType =>
      widget.mediaType == MediaType.movie ? 'movie' : 'tv';

  dynamic get _analyticsContentId => widget.mediaType == MediaType.movie
      ? widget.movieMetadata?.movieId
      : widget.tvMetadata?.tvId;

  String? get _analyticsContentTitle => widget.mediaType == MediaType.movie
      ? widget.movieMetadata?.movieName
      : widget.tvMetadata?.seriesName;

  String? get _analyticsProviderName {
    final code = _currentProviderCode;
    if (code == null || code.trim().isEmpty) return null;
    if (_activeStreamServerName?.trim().isNotEmpty == true) {
      return _activeStreamServerName;
    }
    return _providerDisplayName(code);
  }

  String get _analyticsSurface => widget.useTvControls ? 'tv' : 'standard';

  int get _analyticsElapsedMs =>
      DateTime.now().difference(_analyticsSessionStartedAt).inMilliseconds;

  void _onAnalyticsPlayerEvent(BetterPlayerEvent event) {
    if (_adBlockStopped) return;
    final feedbackValue = _betterPlayerController.videoPlayerController?.value;
    _feedbackSession.onEvent(
      event,
      isAd: _preRollActive,
      isPlaying: feedbackValue?.isPlaying ?? false,
      isBuffering: feedbackValue?.isBuffering ?? false,
      totalBytes: _betterPlayerController.networkBytesTransferred,
    );
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.initialized:
        duration = _betterPlayerController
                .videoPlayerController?.value.duration?.inSeconds ??
            duration;
        final contentAfterPreRoll = _awaitingContentAfterPreRoll;
        _awaitingContentAfterPreRoll = false;
        debugPrint(
          '[Player][IntroDB] player initialized '
          'preRoll=$_preRollActive afterPreRoll=$contentAfterPreRoll '
          'durationSeconds=$duration',
        );
        if (!_preRollActive) unawaited(_loadIntroDbTimings());
        if (contentAfterPreRoll) {
          // The content behind a pre-roll is its first initialization, not a
          // provider switch or recovery.
          _hasPlaybackInitialized = true;
          unawaited(_savePlaybackCache());
          unawaited(_ensurePreferredExternalSubtitle());
          _trackPlaybackEvent('content_initialized');
          if (_recentInsertPending) {
            _recentInsertPending = false;
            _saveRecentProgress();
          }
          break;
        }
        _hasPlaybackInitialized = true;
        unawaited(_savePlaybackCache());
        _analyticsInitializationCount++;
        _trackPlaybackEvent(
          _analyticsInitializationCount == 1 ? 'initialized' : 'reinitialized',
          startupMs:
              _analyticsInitializationCount == 1 ? _analyticsElapsedMs : null,
        );
        break;
      case BetterPlayerEventType.preRollEnded:
        _prerollAd.finish(
          event.parameters?[BetterPlayerController.preRollEndReasonParameter]
                  as String? ??
              'completed',
        );
        _preRollActive = false;
        _completionDetector.reset();
        _playbackCompletionHandled = false;
        // The content's duration, IntroDB lookup and any deferred
        // recently-watched save wait for its initialized event: after a Skip
        // the content has not been prepared yet.
        _awaitingContentAfterPreRoll = true;
        _startupPlaybackWatchStartedAt = DateTime.now();
        _startupTimeoutLogged = false;
        duration = 0;
        _trackPlaybackEvent('pre_roll_ended');
        if (_betterPlayerController.videoPlayerController?.value.isPlaying ==
            true) {
          _wellnessTracker.play();
        }
        break;
      case BetterPlayerEventType.play:
        if (_preRollActive) _prerollAd.onPlay();
        _analyticsPlayingStartedAt ??= DateTime.now();
        if (!_preRollActive) _wellnessTracker.play();
        _trackPlaybackEvent('play');
        _saveRecentProgress();
        _saveWellnessSession();
        break;
      case BetterPlayerEventType.pause:
        if (_preRollActive) _prerollAd.onPause();
        _analyticsWasPlayingBeforeBuffering = false;
        _stopAnalyticsWatchClock();
        _wellnessTracker.pause();
        _trackPlaybackEvent('pause');
        _saveRecentProgress();
        _saveWellnessSession();
        break;
      case BetterPlayerEventType.bufferingStart:
        _analyticsWasPlayingBeforeBuffering =
            _analyticsPlayingStartedAt != null;
        _stopAnalyticsWatchClock();
        _wellnessTracker.pause();
        _analyticsBufferingStartedAt ??= DateTime.now();
        _analyticsBufferCount++;
        _trackPlaybackEvent('buffering_started');
        break;
      case BetterPlayerEventType.bufferingEnd:
        final startedAt = _analyticsBufferingStartedAt;
        final bufferingMs = startedAt == null
            ? 0
            : DateTime.now().difference(startedAt).inMilliseconds;
        _analyticsBufferingMs += bufferingMs;
        _analyticsBufferingStartedAt = null;
        if (_analyticsWasPlayingBeforeBuffering) {
          _analyticsPlayingStartedAt = DateTime.now();
          _wellnessTracker.play();
        }
        _analyticsWasPlayingBeforeBuffering = false;
        _trackPlaybackEvent('buffering_ended', bufferingMs: bufferingMs);
        break;
      case BetterPlayerEventType.exception:
        final error = event.parameters?['exception']?.toString() ??
            'Unknown player error';
        final now = DateTime.now();
        if (error != _lastAnalyticsError ||
            _lastAnalyticsErrorAt == null ||
            now.difference(_lastAnalyticsErrorAt!).inSeconds >= 10) {
          _lastAnalyticsError = error;
          _lastAnalyticsErrorAt = now;
          _trackPlaybackEvent('error', error: error);
        }
        break;
      case BetterPlayerEventType.finished:
        debugPrint('[Player] BetterPlayer reported finished');
        _handlePlaybackCompleted(source: 'native');
        break;
      case BetterPlayerEventType.setupDataSource:
        // A provider switch replaces the sequence while the ad is showing.
        if (!_betterPlayerController.isPreRollActive) {
          _prerollAd.finish('closed');
        }
        _completionDetector.reset();
        _playbackCompletionHandled = false;
        _introDbRequestId++;
        _introDbLoading = false;
        _introDbTimings = IntroDbTimings.empty;
        _activeIntroDbSegment = null;
        _introDbCreditsActive = false;
        _introDbLookupComplete = false;
        _introDbLookupSettled = false;
        _skippedIntroDbSegments.clear();
        break;
      case BetterPlayerEventType.changedResolution:
        final name = event.parameters?['name']?.toString();
        final resolutionName = name ?? 'automatic';
        debugPrint(
          '[PlaybackAdaptive][RESOLUTION_CHANGED] provider=$_currentProviderCode '
          'server=${_activeStreamServerName ?? _currentProviderName()} '
          'quality=$resolutionName activeStreamKey=${_activeStreamUrl?.hashCode}',
        );
        settings.analytics.trackQualityChanged(quality: name ?? 'automatic');
        _trackPlaybackEvent('quality_changed', value: name ?? 'automatic');
        break;
      case BetterPlayerEventType.changedTrack:
        final height = event.parameters?['height'];
        final quality = height == null ? 'automatic' : '${height}p';
        debugPrint(
          '[PlaybackAdaptive][RENDITION_CHANGED] provider=$_currentProviderCode '
          'server=${_activeStreamServerName ?? _currentProviderName()} '
          'quality=$quality activeStreamKey=${_activeStreamUrl?.hashCode}',
        );
        settings.analytics.trackQualityChanged(quality: quality);
        _trackPlaybackEvent('quality_changed', value: quality);
        break;
      case BetterPlayerEventType.changedSubtitles:
        final source = _betterPlayerController.betterPlayerSubtitlesSource;
        final language = source?.type == BetterPlayerSubtitlesSourceType.none
            ? 'off'
            : source?.name ?? 'default';
        settings.analytics.trackSubtitleLanguageChanged(language: language);
        _trackPlaybackEvent('subtitle_changed', value: language);
        break;
      case BetterPlayerEventType.pipStart:
        _inPictureInPicture = true;
        if (mounted) closePlayerPopups(context);
        _nextEpisodeOverlay?.markNeedsBuild();
        break;
      case BetterPlayerEventType.pipStop:
        _inPictureInPicture = false;
        _nextEpisodeOverlay?.markNeedsBuild();
        break;
      case BetterPlayerEventType.controlsVisible:
        _updatePlayerControlsVisibility(true);
        break;
      case BetterPlayerEventType.controlsHiddenStart:
      case BetterPlayerEventType.controlsHiddenEnd:
        _updatePlayerControlsVisibility(false);
        break;
      default:
        break;
    }
  }

  void _updatePlayerControlsVisibility(bool visible) {
    if (_playerControlsVisible == visible) return;
    _playerControlsVisible = visible;
    _nextEpisodeOverlay?.markNeedsBuild();
  }

  void _stopAnalyticsWatchClock() {
    final startedAt = _analyticsPlayingStartedAt;
    if (startedAt == null) return;
    _analyticsWatchedMs += DateTime.now().difference(startedAt).inMilliseconds;
    _analyticsPlayingStartedAt = null;
  }

  bool _isVideoInitializedSafely() {
    if (!_betterPlayerControllerInitialized) return false;
    return _betterPlayerController.videoPlayerController?.value.initialized ==
        true;
  }

  void _trackPlaybackEvent(
    String event, {
    int? startupMs,
    int? bufferingMs,
    String? value,
    String? error,
  }) {
    settings.analytics.trackPlaybackEvent(
      mediaType: _analyticsMediaType,
      contentId: _analyticsContentId,
      contentTitle: _analyticsContentTitle,
      surface: _analyticsSurface,
      sessionId: _analyticsSessionId,
      event: event,
      sessionElapsedMs: _analyticsElapsedMs,
      provider: _analyticsProviderName,
      startupMs: startupMs,
      bufferingMs: bufferingMs,
      bufferCount: _analyticsBufferCount,
      value: value,
      error: error,
    );
  }

  void _startPlaybackMonitor() {
    _progressCheckTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!widget.useTvControls) {
        AdsterraPlaybackAdsService.instance.notePlayerWatch(
            context, Duration(milliseconds: _wellnessTracker.watchedMs()));
      }
      var initialized = false;
      try {
        initialized = _betterPlayerController.isVideoInitialized() == true;
      } catch (error) {
        // Keep the startup watchdog running even while BetterPlayer has not
        // created its native video controller yet.
        debugPrint('[Player] playback monitor waiting for data source: $error');
      }
      final startupWatchStartedAt = _startupPlaybackWatchStartedAt;
      if (startupWatchStartedAt != null && !_preRollActive) {
        final value = _betterPlayerController.videoPlayerController?.value;
        // Background discovery and startup timing are never allowed to select
        // another provider. A genuine decoder/network exception still reaches
        // BetterPlayer's sourceRecoveryHandler; a slow first frame only logs.
        final playbackHasStarted =
            initialized && value != null && value.isPlaying && !value.isBuffering;
        if (playbackHasStarted) {
          _startupPlaybackWatchStartedAt = null;
          _startupTimeoutLogged = false;
        } else if (!_startupTimeoutLogged &&
            DateTime.now().difference(startupWatchStartedAt) >=
                const Duration(seconds: 60)) {
          _startupTimeoutLogged = true;
          debugPrint(
            '[PlaybackStartup][SLOW_START_KEEP_SOURCE] '
            'provider=$_currentProviderCode buffering=${value?.isBuffering ?? false} '
            'initialized=$initialized; waiting for a real player error before failover',
          );
        }
      }

      if (initialized &&
          _betterPlayerController.videoPlayerController != null) {
        final position =
            _betterPlayerController.videoPlayerController!.value.position;
        final duration =
            _betterPlayerController.videoPlayerController!.value.duration;
        final isFullScreen = _betterPlayerController.isFullScreen;
        final value = _betterPlayerController.videoPlayerController!.value;

        final now = DateTime.now();
        if (!_preRollActive &&
            value.isPlaying &&
            !value.isBuffering &&
            (_lastWellnessCheckpointAt == null ||
                now.difference(_lastWellnessCheckpointAt!).inSeconds >= 30)) {
          _lastWellnessCheckpointAt = now;
          _saveWellnessSession();
        }

        if (duration != null && duration.inMilliseconds > 0) {
          if (_preRollActive) return;

          // Completion exclusively owns the post-play surface. Without this
          // guard the periodic monitor sees 100% progress and recreates the
          // teaser immediately after completion removed it.
          if (_playbackCompletionHandled) {
            if (_showNextEpisodeButton || _nextEpisodeOverlay != null) {
              _showNextEpisodeButton = false;
              _hideNextEpisodeOverlay();
            }
            return;
          }

          _updateIntroDbSegment(position, duration);

          final completed = _completionDetector.observe(
            position: position,
            duration: duration,
            isPlaying: value.isPlaying,
            isBuffering: value.isBuffering,
          );
          if (completed) {
            _handlePlaybackCompleted(source: 'position_fallback');
            return;
          }

          if (widget.mediaType != MediaType.tvShow) return;
          final progress = position.inMilliseconds / duration.inMilliseconds;
          final hasIntroDbOutroTiming = _introDbTimings.segments.any(
            (segment) => segment.type == IntroDbSegmentType.credits,
          );
          final introDbOutroReached = _introDbTimings.segments.any(
            (segment) =>
                segment.type == IntroDbSegmentType.credits &&
                position.inMilliseconds >= segment.startMs,
          );
          final shouldShowNextEpisode = shouldShowNextEpisodeTeaser(
            progress: progress,
            introDbLookupSettled: _introDbLookupSettled,
            hasIntroDbOutroTiming: hasIntroDbOutroTiming,
            introDbOutroReached: introDbOutroReached,
          );
          if (progress >= 0.90 || introDbOutroReached) {
            _logNextEpisodeState(
              'near_end',
              position: position,
              duration: duration,
            );
          }

          // An IntroDB outro is authoritative. The percentage threshold is
          // only a fallback once the lookup has settled without an outro.
          // TV playback already owns the full screen route, so Better Player's
          // internal fullscreen flag is intentionally false there.
          if (shouldShowNextEpisode &&
              !_showNextEpisodeButton &&
              !_nextEpisodeButtonDismissed &&
              _hasNextEpisode() &&
              (widget.useTvControls || isFullScreen) &&
              betterPlayerControlsConfiguration.enableNextEpisodeButton) {
            _showNextEpisodeButton = true;
            if (widget.useTvControls) {
              // IntroDB's credits mark are trusted to count down to the next
              // episode; the percentage fallback only offers it.
              _showTvNextEpisodePrompt(
                startCountdown: introDbOutroReached,
                atCredits: true,
              );
            } else {
              _showNextEpisodeOverlay();
            }
          } else if ((!shouldShowNextEpisode ||
                  (!widget.useTvControls && !isFullScreen)) &&
              _showNextEpisodeButton) {
            _showNextEpisodeButton = false;
            _nextEpisodeButtonDismissed = false;
            if (widget.useTvControls) {
              _clearTvNextEpisodePrompt(showControls: false);
            } else {
              _hideNextEpisodeOverlay();
            }
          }
        }
      }
    });
  }

  Future<void> _loadIntroDbTimings() async {
    if (_introDbLoading || _introDbLookupComplete) {
      debugPrint(
        '[Player][IntroDB] lookup skipped: loading=$_introDbLoading '
        'complete=$_introDbLookupComplete',
      );
      return;
    }
    final durationMs = _betterPlayerController
            .videoPlayerController?.value.duration?.inMilliseconds ??
        0;
    final isTv = widget.mediaType == MediaType.tvShow;
    final tmdbId =
        isTv ? widget.tvMetadata?.tvId : widget.movieMetadata?.movieId;
    if (tmdbId == null || tmdbId <= 0) {
      _introDbLookupSettled = true;
      debugPrint(
        '[Player][IntroDB] lookup skipped: missing TMDB ID '
        'mediaType=${widget.mediaType} tvId=${widget.tvMetadata?.tvId} '
        'movieId=${widget.movieMetadata?.movieId}',
      );
      return;
    }
    debugPrint(
      '[Player][IntroDB] loading '
      'mediaType=${isTv ? 'tv' : 'movie'} tmdbId=$tmdbId '
      'season=${widget.tvMetadata?.seasonNumber} '
      'episode=${widget.tvMetadata?.episodeNumber} durationMs=$durationMs',
    );
    _introDbLoading = true;
    _introDbLookupSettled = false;
    final requestId = ++_introDbRequestId;
    try {
      final timings = await _introDbService.fetch(
        tmdbId: tmdbId,
        isTv: isTv,
        season: widget.tvMetadata?.seasonNumber,
        episode: widget.tvMetadata?.episodeNumber,
        durationMs: durationMs > 0 ? durationMs : null,
      );
      if (!mounted || requestId != _introDbRequestId) return;
      setState(() {
        _introDbTimings = timings;
        _activeIntroDbSegment = null;
        _skippedIntroDbSegments.clear();
      });
      _introDbLookupComplete = true;
      debugPrint(
        '[Player][IntroDB] timings ready count=${timings.segments.length}',
      );
    } catch (error) {
      if (requestId == _introDbRequestId) {
        _introDbLookupComplete = false;
        debugPrint('[Player][IntroDB] timings unavailable: $error');
      }
    } finally {
      if (requestId == _introDbRequestId) {
        _introDbLoading = false;
        _introDbLookupSettled = true;
      }
    }
  }

  bool _introDbTypeEnabled(IntroDbSegmentType type) {
    return settings.enableIntroDbSkipButtons;
  }

  String _segmentKey(IntroDbSegment segment) =>
      '${segment.type.name}:${segment.startMs}:${segment.endMs}';

  void _updateIntroDbSegment(Duration position, Duration duration) {
    if (_introDbTimings.segments.isEmpty) return;
    final positionMs = position.inMilliseconds;
    IntroDbSegment? active;
    var creditsActive = false;
    for (final segment in _introDbTimings.segments) {
      final endMs = segment.endMs ?? duration.inMilliseconds;
      final contains = positionMs >= segment.startMs && positionMs < endMs;
      if (contains && segment.type == IntroDbSegmentType.credits) {
        creditsActive = true;
      }
      if (active == null &&
          contains &&
          settings.enableIntroDbSkipButtons &&
          _introDbTypeEnabled(segment.type) &&
          !_skippedIntroDbSegments.contains(_segmentKey(segment))) {
        active = segment;
      }
    }
    final creditsStateChanged = creditsActive != _introDbCreditsActive;
    _introDbCreditsActive = creditsActive;
    if (creditsStateChanged) {
      debugPrint('[Player][IntroDB] credits active=$creditsActive');
    }
    if (creditsActive &&
        !_playbackCompletionHandled &&
        settings.enableNextEpisodeButton &&
        widget.mediaType == MediaType.tvShow &&
        _hasNextEpisode() &&
        (widget.useTvControls || _betterPlayerController.isFullScreen) &&
        !_showNextEpisodeButton) {
      _showNextEpisodeButton = true;
      if (widget.useTvControls) {
        _showTvNextEpisodePrompt(startCountdown: true, atCredits: true);
      } else {
        _showNextEpisodeOverlay();
      }
    }
    if (active != _activeIntroDbSegment) {
      debugPrint(
        '[Player][IntroDB] active segment '
        '${active == null ? 'none' : '${active.type.name} '
            '${active.startMs}-${active.endMs ?? duration.inMilliseconds}'}',
      );
    }
    if (active != _activeIntroDbSegment && mounted) {
      setState(() => _activeIntroDbSegment = active);
      _nextEpisodeOverlay?.markNeedsBuild();
    }
    if (active == null) {
      for (final segment in _introDbTimings.segments) {
        if (positionMs < segment.startMs) {
          _skippedIntroDbSegments.remove(_segmentKey(segment));
        }
      }
    }
  }

  void _skipActiveIntroDbSegment() {
    final segment = _activeIntroDbSegment;
    if (segment == null) return;
    final duration =
        _betterPlayerController.videoPlayerController?.value.duration;
    final endMs = segment.endMs ?? duration?.inMilliseconds;
    if (endMs == null || endMs <= segment.startMs) return;
    _skippedIntroDbSegments.add(_segmentKey(segment));
    debugPrint(
      '[Player][IntroDB] skipping ${segment.type.name} '
      '${segment.startMs}ms -> ${endMs}ms',
    );
    setState(() => _activeIntroDbSegment = null);
    _nextEpisodeOverlay?.markNeedsBuild();
    // IntroDB is always user-driven. This is the only IntroDB path that seeks,
    // and it is invoked exclusively by the visible skip button.
    unawaited(_betterPlayerController.seekTo(Duration(milliseconds: endMs)));
  }

  String _introDbLabel(IntroDbSegmentType type) => switch (type) {
        IntroDbSegmentType.intro => tr('skip_intro'),
        IntroDbSegmentType.recap => tr('skip_recap'),
        IntroDbSegmentType.credits => tr('skip_credits'),
        IntroDbSegmentType.preview => tr('skip_preview'),
      };

  /// The controls keep this button outside their fade, so they ask whether it
  /// has anything to skip before giving it space. On television the TV menu and
  /// the next-episode prompt own the select key while they are up, so the skip
  /// button steps aside rather than competing with them.
  bool _canSkipIntroDbSegment() =>
      _activeIntroDbSegment != null &&
      widget.settings.enableIntroDbSkipButtons &&
      (!widget.useTvControls ||
          (_tvMenu == null &&
              _tvNextEpisode == null &&
              !_tvSubtitleTimingOpen));

  Widget _buildIntroDbSkipButton(BuildContext context) {
    final segment = _activeIntroDbSegment;
    if (segment == null || !_canSkipIntroDbSegment()) {
      return const SizedBox.shrink();
    }
    return _TvSkipButton(
      label: _introDbLabel(segment.type),
      onPressed: _skipActiveIntroDbSegment,
    );
  }

  bool _hasNextEpisode() {
    _restoreEpisodeSnapshotIfNeeded('has_next_episode');
    final episodes = widget.tvMetadata?.seasonEpisodes;
    if (episodes == null || episodes.isEmpty) {
      return false;
    }

    final currentIndex = _currentEpisodeIndex();

    return currentIndex >= 0 && currentIndex < episodes.length - 1;
  }

  void _restoreEpisodeSnapshotIfNeeded(String stage) {
    final metadata = widget.tvMetadata;
    if (metadata == null ||
        metadata.seasonEpisodes?.isNotEmpty == true ||
        _contentMenuEpisodes.isEmpty) {
      return;
    }
    metadata.seasonEpisodes = List<EpisodeMetadata>.of(_contentMenuEpisodes);
    debugPrint(
      '[NextEpisodeDebug][episodes_restored] stage=$stage '
      'snapshotEpisodes=${_contentMenuEpisodes.length} '
      'current=S${metadata.seasonNumber}E${metadata.episodeNumber}',
    );
  }

  void _logNextEpisodeState(
    String stage, {
    Duration? position,
    Duration? duration,
    bool force = false,
  }) {
    _restoreEpisodeSnapshotIfNeeded(stage);
    final metadata = widget.tvMetadata;
    final episodes = metadata?.seasonEpisodes;
    final currentIndex = _currentEpisodeIndex();
    final strictIndex = episodes?.indexWhere(
          (episode) =>
              episode.episodeNumber == metadata?.episodeNumber &&
              episode.seasonNumber == metadata?.seasonNumber,
        ) ??
        -1;
    final hasNext = episodes != null &&
        currentIndex >= 0 &&
        currentIndex < episodes.length - 1;
    final nextEpisode = hasNext ? episodes[currentIndex + 1] : null;
    final isFullScreen = _betterPlayerControllerInitialized
        ? _betterPlayerController.isFullScreen
        : null;
    final hasIntroDbOutroTiming = _introDbTimings.segments.any(
      (segment) => segment.type == IntroDbSegmentType.credits,
    );
    final introDbOutroReached = position != null &&
        _introDbTimings.segments.any(
          (segment) =>
              segment.type == IntroDbSegmentType.credits &&
              position.inMilliseconds >= segment.startMs,
        );
    final signature = <Object?>[
      stage,
      metadata?.seasonNumber,
      metadata?.episodeNumber,
      metadata?.episodeId,
      episodes?.length,
      currentIndex,
      strictIndex,
      nextEpisode?.seasonNumber,
      nextEpisode?.episodeNumber,
      hasNext,
      widget.useTvControls,
      isFullScreen,
      betterPlayerControlsConfiguration.enableNextEpisodeButton,
      _showNextEpisodeButton,
      _nextEpisodeButtonDismissed,
      _introDbCreditsActive,
      _introDbLookupSettled,
      hasIntroDbOutroTiming,
      introDbOutroReached,
    ].join('|');
    if (!force && signature == _lastNextEpisodeDebugSignature) return;
    _lastNextEpisodeDebugSignature = signature;
    final progress = position != null &&
            duration != null &&
            duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).toStringAsFixed(4)
        : 'n/a';
    debugPrint(
      '[NextEpisodeDebug][$stage] media=S${metadata?.seasonNumber}'
      'E${metadata?.episodeNumber} episodeId=${metadata?.episodeId} '
      'episodes=${episodes?.length ?? 0} currentIndex=$currentIndex '
      'strictIndex=$strictIndex hasNext=$hasNext '
      'next=S${nextEpisode?.seasonNumber}E${nextEpisode?.episodeNumber} '
      'progress=$progress positionMs=${position?.inMilliseconds} '
      'durationMs=${duration?.inMilliseconds} tvControls=${widget.useTvControls} '
      'fullscreen=$isFullScreen setting='
      '${betterPlayerControlsConfiguration.enableNextEpisodeButton} '
      'show=$_showNextEpisodeButton dismissed=$_nextEpisodeButtonDismissed '
      'credits=$_introDbCreditsActive introDbSettled=$_introDbLookupSettled '
      'outroTiming=$hasIntroDbOutroTiming outroReached=$introDbOutroReached',
    );
  }

  int _currentEpisodeIndex() {
    _restoreEpisodeSnapshotIfNeeded('current_episode_index');
    final metadata = widget.tvMetadata;
    final episodes = metadata?.seasonEpisodes;
    if (metadata == null || episodes == null || episodes.isEmpty) return -1;

    final bySeasonAndNumber = episodes.indexWhere(
      (episode) =>
          episode.episodeNumber == metadata.episodeNumber &&
          (metadata.seasonNumber == null ||
              episode.seasonNumber == metadata.seasonNumber),
    );
    if (bySeasonAndNumber >= 0) return bySeasonAndNumber;

    final episodeId = metadata.episodeId;
    if (episodeId == null) return -1;
    return episodes.indexWhere((episode) => episode.episodeId == episodeId);
  }

  void _showNextEpisodeOverlay() {
    _logNextEpisodeState('floating_overlay_requested', force: true);
    if (_playbackCompletionHandled) {
      debugPrint(
        '[NextEpisodeDebug][floating_overlay_skipped] reason=completed',
      );
      return;
    }
    if (_nextEpisodeOverlay != null) {
      debugPrint(
        '[NextEpisodeDebug][floating_overlay_skipped] reason=already_inserted',
      );
      return;
    }

    final nextEpisode = _nextTvEpisode;
    if (nextEpisode == null) return;
    _phoneNextEpisode = nextEpisode;
    _phoneNextEpisodeCountdown = null;
    _nextEpisodeOverlay = OverlayEntry(builder: _buildPhoneNextEpisodeCard);

    Overlay.of(context, rootOverlay: true).insert(_nextEpisodeOverlay!);
    debugPrint(
      '[NextEpisodeDebug][floating_overlay_inserted] '
      'overlay=${identityHashCode(Overlay.of(context, rootOverlay: true))}',
    );
  }

  void _hideNextEpisodeOverlay() {
    _phoneNextEpisodeTimer?.cancel();
    _phoneNextEpisodeTimer = null;
    _phoneNextEpisode = null;
    _phoneNextEpisodeCountdown = null;
    _nextEpisodeOverlay?.remove();
    _nextEpisodeOverlay = null;
  }

  /// At the end of an episode on the phone: the card, counting down to the
  /// next one.
  void _showPhoneNextEpisodeCountdown(EpisodeMetadata nextEpisode) {
    _hideNextEpisodeOverlay();
    if (!mounted) return;
    _phoneNextEpisode = nextEpisode;
    _phoneNextEpisodeCountdown = _endCountdown;
    _nextEpisodeOverlay = OverlayEntry(builder: _buildPhoneNextEpisodeCard);
    Overlay.of(context, rootOverlay: true).insert(_nextEpisodeOverlay!);
    _phoneNextEpisodeTimer =
        Timer.periodic(const Duration(seconds: 1), (timer) {
      final countdown = _phoneNextEpisodeCountdown;
      if (!mounted || countdown == null) {
        timer.cancel();
        return;
      }
      if (countdown <= 1) {
        timer.cancel();
        _hideNextEpisodeOverlay();
        unawaited(_playNextEpisodeFromControls());
        return;
      }
      _phoneNextEpisodeCountdown = countdown - 1;
      _nextEpisodeOverlay?.markNeedsBuild();
    });
  }

  Widget _buildPhoneNextEpisodeCard(BuildContext context) {
    final episode = _phoneNextEpisode;
    if (episode == null || _inPictureInPicture) return const SizedBox.shrink();
    final counting = _phoneNextEpisodeCountdown != null;
    return _TvNextEpisodeOverlay(
      touch: true,
      liftedBy: _playerControlsVisible ? 128 : 0,
      episode: episode,
      countdown: _phoneNextEpisodeCountdown,
      countdownTotal: _endCountdown,
      cancelLabel: counting ? tr('cancel') : tr('watch_credits'),
      onCancel: () {
        if (!counting) {
          _nextEpisodeButtonDismissed = true;
          _showNextEpisodeButton = false;
        }
        _hideNextEpisodeOverlay();
      },
      busy: _startingContent,
      onPlay: () async {
        _phoneNextEpisodeTimer?.cancel();
        await _playNextEpisodeFromControls();
      },
    );
  }

  void startDurationTimer() {
    if (_durationTimer == null) {
      _durationTimer =
          Timer.periodic(const Duration(seconds: 1), (Timer timer) {
        setState(() {
          playbackDurationInSeconds++;
        });
      });

      _resetTimer = Timer.periodic(const Duration(seconds: 60), (Timer timer) {
        resetDurationTimer();
      });
    }
  }

  BetterPlayerDataSource _buildDataSource({
    required Map<String, String> sources,
    required List<BetterPlayerSubtitlesSource> subtitles,
    required Map<String, BetterPlayerVideoFormat?>? videoFormats,
    required Map<String, Map<String, String>> videoHeaders,
    String? selectedResolution,
  }) {
    final selectedSource = selectedResolution != null &&
            sources.containsKey(selectedResolution)
        ? MapEntry(selectedResolution, sources[selectedResolution]!)
        : VideoUtils.preferredVideoSource(
            sources,
            widget.settings.defaultVideoResolution,
          )!;
    final link = selectedSource.value;
    final suppliedHeaders = videoHeaders[selectedSource.key];
    final resolvedHeaders = suppliedHeaders?.isNotEmpty == true
        ? suppliedHeaders!
        : VideoUtils.inferVideoHeaders(link) ?? const <String, String>{};
    final sourceUri = Uri.tryParse(link);
    final resolvedFormat =
        videoFormats?[selectedSource.key] ?? _inferVideoFormat(link);
    debugPrint(
      '[PlaybackStartup][DATA_SOURCE] provider=$_currentProviderCode '
      'host=${sourceUri?.host ?? 'invalid'} '
      'format=${resolvedFormat?.name ?? 'progressive-or-unknown'} '
      'headers=${resolvedHeaders.keys.join(',')}',
    );
    final resolutionVideoFormats = <String, BetterPlayerVideoFormat?>{
      for (final source in sources.entries)
        source.key:
            videoFormats?[source.key] ?? _inferVideoFormat(source.value),
    };
    final resolutionHeaders = <String, Map<String, String>>{
      for (final source in sources.entries)
        source.key: videoHeaders[source.key]?.isNotEmpty == true
            ? videoHeaders[source.key]!
            : VideoUtils.inferVideoHeaders(source.value) ??
                const <String, String>{},
    };
    final resolutionDisplayNames = <String, String>{
      for (final source in sources.entries)
        source.key: _resolutionDisplayName(source.key),
    };
    final resolutionDescriptions = _resolutionDescriptions(sources);

    final appSuppliedSubtitles = <BetterPlayerSubtitlesSource>[
      ...subtitles,
      ..._localSubtitles.appliedSubtitles,
      ..._externalSubtitles.appliedSubtitles,
    ];

    return BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      link,
      resolutions: sources.length > 1 ? sources : null,
      selectedResolution: selectedSource.key,
      resolutionVideoFormats:
          sources.length > 1 ? resolutionVideoFormats : null,
      resolutionHeaders: sources.length > 1 ? resolutionHeaders : null,
      resolutionDisplayNames:
          sources.length > 1 ? resolutionDisplayNames : null,
      resolutionDescriptions:
          sources.length > 1 ? resolutionDescriptions : null,
      videoFormat: resolvedFormat,
      headers: resolvedHeaders,
      castConfiguration: widget.useTvControls
          ? null
          : BetterPlayerCastConfiguration(
              title: widget.mediaType == MediaType.movie
                  ? widget.movieMetadata?.movieName
                  : widget.tvMetadata?.seriesName,
              subtitle: widget.mediaType == MediaType.movie
                  ? widget.movieMetadata?.releaseYear?.toString()
                  : 'S${widget.tvMetadata?.seasonNumber ?? 0} '
                      'E${widget.tvMetadata?.episodeNumber ?? 0} · '
                      '${widget.tvMetadata?.episodeName ?? ''}',
              imageUrl: _castArtworkUrl(),
              contentType: _castContentType(
                videoFormats?[selectedSource.key] ?? _inferVideoFormat(link),
              ),
              requestHeaders: resolvedHeaders,
              customData: <String, Object?>{
                'mediaType':
                    widget.mediaType == MediaType.movie ? 'movie' : 'tv',
                'mediaId': widget.mediaType == MediaType.movie
                    ? widget.movieMetadata?.movieId
                    : widget.tvMetadata?.tvId,
                if (widget.tvMetadata != null)
                  'seasonNumber': widget.tvMetadata!.seasonNumber,
                if (widget.tvMetadata != null)
                  'episodeNumber': widget.tvMetadata!.episodeNumber,
              },
            ),
      subtitles: appSuppliedSubtitles,
      // Streaming already has a bounded in-memory buffer. A persistent media
      // cache can fill the limited internal storage available on Android TVs.
      cacheConfiguration: const BetterPlayerCacheConfiguration(useCache: false),
      bufferingConfiguration: betterPlayerBufferingConfiguration,
    );
  }

  String _resolutionDisplayName(String sourceKey) {
    final separator = sourceKey.indexOf(' · ');
    return separator < 0 ? sourceKey : sourceKey.substring(0, separator);
  }

  Map<String, String> _resolutionDescriptions(Map<String, String> sources) => {
        for (final key in sources.keys)
          if (key.contains(' · ')) key: key.split(' · ').skip(1).join(' · '),
      };

  String? _castArtworkUrl() {
    final path = widget.mediaType == MediaType.movie
        ? widget.movieMetadata?.backdropPath ?? widget.movieMetadata?.posterPath
        : widget.tvMetadata?.backdropPath ?? widget.tvMetadata?.posterPath;
    return path == null || path.isEmpty
        ? null
        : '${TMDB_BASE_IMAGE_URL}w780$path';
  }

  String _castContentType(BetterPlayerVideoFormat? format) => switch (format) {
        BetterPlayerVideoFormat.hls => 'application/x-mpegURL',
        BetterPlayerVideoFormat.dash => 'application/dash+xml',
        _ => 'video/mp4',
      };

  void _applyPreferredAdaptiveQuality() {
    final preferredHeight = widget.settings.defaultVideoResolution;
    if (preferredHeight == 0) return;

    final tracks = _betterPlayerController.betterPlayerAsmsTracks
        .where((track) => (track.height ?? 0) > 0)
        .toList();
    if (tracks.isEmpty) return;

    final exact = tracks.where((track) => track.height == preferredHeight);
    if (exact.isNotEmpty) {
      debugPrint(
        '[PlaybackAdaptive][PREFERRED_TRACK] provider=$_currentProviderCode '
        'requested=${preferredHeight}p selected=${exact.first.height}p',
      );
      _betterPlayerController.setTrack(exact.first);
      return;
    }

    final atOrBelow = tracks.where(
      (track) => track.height! <= preferredHeight,
    );
    if (atOrBelow.isNotEmpty) {
      final selected = atOrBelow.reduce(
        (best, track) => track.height! > best.height! ? track : best,
      );
      debugPrint(
        '[PlaybackAdaptive][PREFERRED_TRACK] provider=$_currentProviderCode '
        'requested=${preferredHeight}p selected=${selected.height}p fallback=at_or_below',
      );
      _betterPlayerController.setTrack(selected);
      return;
    }
    final selected = tracks.reduce(
      (best, track) => track.height! < best.height! ? track : best,
    );
    debugPrint(
      '[PlaybackAdaptive][PREFERRED_TRACK] provider=$_currentProviderCode '
      'requested=${preferredHeight}p selected=${selected.height}p fallback=lowest_available',
    );
    _betterPlayerController.setTrack(selected);
  }

  BetterPlayerVideoFormat? _inferVideoFormat(String? url) {
    if (url == null || url.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(url);
    final path = uri?.path.toLowerCase() ?? url.toLowerCase();
    if (path.endsWith('.m3u8') || path.contains('/playlist/')) {
      return BetterPlayerVideoFormat.hls;
    }

    if (path.endsWith('.mpd')) {
      return BetterPlayerVideoFormat.dash;
    }

    return null;
  }

  void pauseDurationTimer() {
    updateAndLogTotalStreamingDuration(playbackDurationInSeconds);
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  void resetDurationTimer() {
    setState(() {
      playbackDurationInSeconds = 0;
    });
  }

  /// During the pre-roll the player's position and duration are the ad's, so
  /// saving now would overwrite the resume point. Save once the content runs.
  bool _deferRecentInsertDuringPreRoll() {
    if (!_preRollActive && !_awaitingContentAfterPreRoll) return false;
    _recentInsertPending = true;
    return true;
  }

  Future<void> insertRecentMovieData() async {
    if (!mounted) return;
    if (_deferRecentInsertDuringPreRoll()) return;
    await _dataManagement.insertRecentMovieData(
      context: context,
      betterPlayerController: _betterPlayerController,
      duration: duration,
      movieMetadata: widget.movieMetadata!,
    );
  }

  Future<void> insertRecentEpisodeData() async {
    if (!mounted) return;
    if (_deferRecentInsertDuringPreRoll()) return;
    await _dataManagement.insertRecentEpisodeData(
      context: context,
      betterPlayerController: _betterPlayerController,
      duration: duration,
      tvMetadata: widget.tvMetadata!,
    );
  }

  void _saveRecentProgress() {
    savePlayerDataInBackground(
      widget.mediaType == MediaType.movie
          ? insertRecentMovieData
          : insertRecentEpisodeData,
      operation: 'playback progress',
    );
  }

  /// Close the player (pop navigation)
  void _closePlayer() {
    Navigator.pop(context);
  }

  BuildContext get _playerModalContext {
    // Fullscreen Better Player controls live on a separate root route. Use
    // the active navigator overlay so sheets are pushed above that route.
    final navigator = Navigator.of(context, rootNavigator: true);
    return navigator.overlay?.context ?? context;
  }

  MovieStreamMetadata? get _movieMetadataForContentMenu => widget.movieMetadata;

  TVStreamMetadata? get _tvMetadataForContentMenu {
    final metadata = widget.tvMetadata;
    if (metadata != null &&
        metadata.seasonEpisodes?.isNotEmpty != true &&
        _contentMenuEpisodes.isNotEmpty) {
      metadata.seasonEpisodes = List<EpisodeMetadata>.of(_contentMenuEpisodes);
      debugPrint(
        '[PlayerContentMenu] restored '
        '${metadata.seasonEpisodes!.length} season episodes',
      );
    }
    if (metadata != null &&
        metadata.allSeasons?.isNotEmpty != true &&
        _contentMenuSeasons.isNotEmpty) {
      metadata.allSeasons = List<SeasonMetadata>.of(_contentMenuSeasons);
    }
    return metadata;
  }

  Future<void> _openEpisodeList() async {
    debugPrint(
      '[PlayerContentMenu] open episodes requested '
      'mounted=$mounted menuOpen=$_isContentMenuOpen '
      'useTvControls=${widget.useTvControls}',
    );
    if (!mounted) {
      debugPrint('[PlayerContentMenu] episodes aborted: player unmounted');
      return;
    }
    if (_isContentMenuOpen) {
      debugPrint('[PlayerContentMenu] episodes aborted: menu already open');
      return;
    }
    if (widget.useTvControls) {
      debugPrint('[PlayerContentMenu] episodes routed to TV menu');
      _showTvEpisodeMenu();
      return;
    }

    final metadata = _tvMetadataForContentMenu;
    if (metadata?.seasonEpisodes?.isNotEmpty != true) {
      debugPrint('[PlayerContentMenu] episodes aborted: metadata is empty');
      return;
    }
    _isContentMenuOpen = true;
    try {
      final menuContext = _playerModalContext;
      final navigator = Navigator.of(menuContext, rootNavigator: true);
      debugPrint(
        '[PlayerContentMenu] showing episodes sheet '
        'episodes=${metadata!.seasonEpisodes!.length} '
        'context=${identityHashCode(menuContext)} '
        'overlay=${identityHashCode(navigator.overlay)} '
        'canPop=${navigator.canPop()}',
      );
      await _episodeSelection.showEpisodeSelectionBottomSheet(
        context: menuContext,
        colors: widget.colors,
        tvMetadata: metadata,
        onSaveProgress: _handleContentSwitch,
        closePlayer: _closePlayer,
      );
      debugPrint('[PlayerContentMenu] episodes sheet future completed');
    } catch (error, stackTrace) {
      _reportContentMenuError(error, stackTrace);
    } finally {
      _isContentMenuOpen = false;
      debugPrint('[PlayerContentMenu] episodes menu state reset');
    }
  }

  Future<void> _openMovieRecommendations() async {
    debugPrint(
      '[PlayerContentMenu] open recommendations requested '
      'mounted=$mounted menuOpen=$_isContentMenuOpen '
      'useTvControls=${widget.useTvControls}',
    );
    if (!mounted) {
      debugPrint(
          '[PlayerContentMenu] recommendations aborted: player unmounted');
      return;
    }
    if (_isContentMenuOpen) {
      debugPrint(
          '[PlayerContentMenu] recommendations aborted: menu already open');
      return;
    }
    if (widget.useTvControls) {
      debugPrint('[PlayerContentMenu] recommendations routed to TV menu');
      _showTvMovieRecommendationsMenu();
      return;
    }

    final metadata = _movieMetadataForContentMenu;
    if (metadata?.recommendations?.isNotEmpty != true) {
      debugPrint(
          '[PlayerContentMenu] recommendations aborted: metadata is empty');
      return;
    }
    _isContentMenuOpen = true;
    try {
      final menuContext = _playerModalContext;
      final navigator = Navigator.of(menuContext, rootNavigator: true);
      debugPrint(
        '[PlayerContentMenu] showing recommendations sheet '
        'recommendations=${metadata!.recommendations!.length} '
        'context=${identityHashCode(menuContext)} '
        'overlay=${identityHashCode(navigator.overlay)} '
        'canPop=${navigator.canPop()}',
      );
      await _movieRecommendations.showMovieRecommendationsBottomSheet(
        context: menuContext,
        colors: widget.colors,
        movieMetadata: metadata,
        onSaveProgress: _handleContentSwitch,
        closePlayer: _closePlayer,
      );
      debugPrint('[PlayerContentMenu] recommendations sheet future completed');
    } catch (error, stackTrace) {
      _reportContentMenuError(error, stackTrace);
    } finally {
      _isContentMenuOpen = false;
      debugPrint('[PlayerContentMenu] recommendations menu state reset');
    }
  }

  void _reportContentMenuError(Object error, StackTrace stackTrace) {
    debugPrint('[PlayerContentMenu] unable to open content menu: $error');
    debugPrintStack(stackTrace: stackTrace);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(tr('error_occured'))),
    );
  }

  void _saveWellnessSession({
    bool completed = false,
    bool syncImmediately = false,
  }) {
    savePlayerDataInBackground(
      () => _persistWellnessSession(
        completed: completed,
        syncImmediately: syncImmediately,
      ),
      operation: 'wellness session',
    );
  }

  Future<void> _persistWellnessSession({
    bool completed = false,
    bool syncImmediately = false,
  }) async {
    if (_preRollActive || _awaitingContentAfterPreRoll) return;
    // Requested before the first await so it reaches the player ahead of a
    // dispose that follows this call.
    final networkBytes = _flushNetworkUsage();
    final value = _betterPlayerController.videoPlayerController?.value;
    final positionMs = value?.position.inMilliseconds ?? 0;
    final durationMs = value?.duration?.inMilliseconds ?? duration * 1000;
    final isMovie = widget.mediaType == MediaType.movie;
    final movie = widget.movieMetadata;
    final episode = widget.tvMetadata;
    final rawId = isMovie ? movie?.movieId : episode?.episodeId;
    final fallbackEpisodeId = episode == null
        ? null
        : '${episode.tvId ?? 'unknown'}:${episode.seasonNumber ?? 0}:'
            '${episode.episodeNumber ?? 0}';
    final contentId = rawId?.toString() ?? fallbackEpisodeId;
    final title = isMovie ? movie?.movieName : episode?.seriesName;
    if (contentId == null || title == null || title.trim().isEmpty) return;
    final releaseDate = isMovie ? movie?.releaseDate : episode?.airDate;
    await WellnessProvider.instance.recordPlayback(
      sessionId: _analyticsSessionId,
      tracker: _wellnessTracker,
      mediaType: isMovie ? WellnessMediaType.movie : WellnessMediaType.episode,
      source: WellnessPlaybackSource.streaming,
      contentId: contentId,
      seriesId: isMovie ? null : episode?.tvId?.toString(),
      title: title,
      subtitle: isMovie ? null : episode?.episodeName,
      seasonNumber: episode?.seasonNumber,
      episodeNumber: episode?.episodeNumber,
      durationMs: durationMs,
      progressEndMs: positionMs,
      completed: completed,
      posterPath: isMovie ? movie?.posterPath : episode?.posterPath,
      backdropPath: isMovie ? movie?.backdropPath : episode?.backdropPath,
      releaseYear: isMovie
          ? movie?.releaseYear
          : DateTime.tryParse(releaseDate ?? '')?.year,
      provider: _analyticsProviderName,
      genres: isMovie ? movie?.genres ?? const [] : episode?.genres ?? const [],
      languages: isMovie
          ? movie?.languages ?? const []
          : episode?.languages ?? const [],
      countries: isMovie
          ? movie?.countries ?? const []
          : episode?.countries ?? const [],
      networkBytes: await networkBytes,
      syncImmediately: syncImmediately,
    );
  }

  /// The network data this player has used so far, or null where the
  /// platform does not measure it.
  Future<int?> _flushNetworkUsage() async {
    try {
      return await _betterPlayerController.flushNetworkUsage();
    } catch (error) {
      debugPrint('[Player] network usage unavailable: $error');
      return _betterPlayerController.networkBytesTransferred;
    }
  }

  /// Captures the outgoing content now; persistence must not hold navigation.
  void _handleContentSwitch() {
    if (!mounted) return;
    savePlayerDataInBackground(
      () => _dataManagement.handleContentSwitch(
        context: context,
        mediaType: widget.mediaType!,
        betterPlayerController: _betterPlayerController,
        duration: duration,
        playbackDurationInSeconds: playbackDurationInSeconds,
        movieMetadata: widget.movieMetadata,
        tvMetadata: widget.tvMetadata,
      ),
      operation: 'playback progress on content switch',
    );
    _saveWellnessSession(
      completed: _playbackCompletionHandled,
      syncImmediately: true,
    );

    _automaticReportEndReason = 'content_switch';
    // Reset playback duration timer for next content
    playbackDurationInSeconds = 0;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    final isInBackground = (state == AppLifecycleState.paused) ||
        (state == AppLifecycleState.inactive);
    if (isInBackground) {
      _saveWellnessSession(
        completed: _playbackCompletionHandled,
        syncImmediately: true,
      );
      if (_isVideoInitializedSafely()) {
        _saveRecentProgress();
      }
    }
  }

  @override
  void dispose() {
    _streamingDnd.dispose();
    _sendAutomaticStreamReport();
    _feedbackConnection.dispose();
    _hideContentSwitchLoading();
    _betterPlayerControllerInitialized = false;
    _prerollAd.dispose();
    settings.removeListener(_syncAmbientGlowSetting);
    settings.removeListener(_syncAutoPipSetting);
    final suppressionId = _occasionalEffectsSuppressionId;
    if (suppressionId != null) {
      _occasionalEffectsSuppressionId = null;
      // Keep effects suppressed through the outgoing route frame. This also
      // overlaps safely with a replacement player's newly acquired scope.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _appDependencies.releaseOccasionalEffectsSuppression(suppressionId);
      });
    }
    // _resetTimer?.cancel();
    _progressCheckTimer?.cancel();
    _tvNextEpisodeTimer?.cancel();
    _hideNextEpisodeOverlay();

    // Restore original brightness before disposing
    BetterPlayerBrightnessManager.restoreOriginalBrightness();
    PlaybackWakeLock.instance.release(this);

    unawaited(_providerScanSubscription?.cancel());
    widget.providerScanSession?.cancel();
    _adaptiveQualityScanner.dispose();
    _streamCatalogRevision.dispose();
    _betterPlayerController.removeEventsListener(_onAnalyticsPlayerEvent);
    _stopAnalyticsWatchClock();
    _wellnessTracker.pause();
    final bufferingStartedAt = _analyticsBufferingStartedAt;
    if (bufferingStartedAt != null) {
      _analyticsBufferingMs +=
          DateTime.now().difference(bufferingStartedAt).inMilliseconds;
    }
    settings.analytics.trackPlaybackSessionEnded(
      mediaType: _analyticsMediaType,
      contentId: _analyticsContentId,
      contentTitle: _analyticsContentTitle,
      surface: _analyticsSurface,
      sessionId: _analyticsSessionId,
      durationMs: _analyticsElapsedMs,
      watchedMs: _analyticsWatchedMs,
      bufferingMs: _analyticsBufferingMs,
      bufferCount: _analyticsBufferCount,
      providerSwitchCount: _analyticsProviderSwitchCount,
      provider: _analyticsProviderName,
    );
    _saveWellnessSession(
      completed: _playbackCompletionHandled,
      syncImmediately: true,
    );

    // Dispose the BetterPlayer controller to clean up resources
    _betterPlayerController.dispose();
    _introService.close();
    _introDbService.close();

    // Reset orientation to portrait when leaving the player
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _stopForAdBlocker() {
    if (_adBlockStopped) return;
    if (_isVideoInitializedSafely()) _saveRecentProgress();
    _adBlockStopped = true;
    _exitingPlayer = true;
    _automaticReportEndReason = 'ad_blocked';
    _durationTimer?.cancel();
    _progressCheckTimer?.cancel();
    _phoneNextEpisodeTimer?.cancel();
    _tvNextEpisodeTimer?.cancel();
    _hideNextEpisodeOverlay();
    _prerollAd.dispose();
    // Force native teardown now, before any route transition or message.
    _betterPlayerController.dispose(forceDispose: true);
  }

  void _handleVideoFinished() {
    if (widget.mediaType == MediaType.tvShow) {
      _restoreEpisodeSnapshotIfNeeded('video_finished');
    }
    if (widget.mediaType == MediaType.tvShow) {
      _logNextEpisodeState('video_finished', force: true);
    }
    debugPrint(
      '[MovieRecommendationsDebug][VIDEO_FINISHED_ENTER] '
      'mediaType=${widget.mediaType} mounted=$mounted '
      'useTvControls=${widget.useTvControls} '
      'movieId=${widget.movieMetadata?.movieId} '
      'recommendations=${widget.movieMetadata?.recommendations?.length ?? 0}',
    );
    if (widget.mediaType == MediaType.tvShow &&
        widget.tvMetadata?.seasonEpisodes != null &&
        widget.tvMetadata!.seasonEpisodes!.isNotEmpty) {
      final episodes = widget.tvMetadata!.seasonEpisodes!;
      final currentIndex = _currentEpisodeIndex();

      // Check if there's a next episode
      if (currentIndex >= 0 && currentIndex < episodes.length - 1) {
        final nextEpisode = episodes[currentIndex + 1];

        if (widget.useTvControls) {
          // Having chosen to watch the credits, the end still moves on, as
          // Netflix does; the count leaves time to stop it.
          _showTvNextEpisodePrompt(startCountdown: true);
        } else {
          // Show countdown dialog for next episode
          debugPrint(
            '[NextEpisodeDebug][countdown_requested] '
            'next=S${nextEpisode.seasonNumber}E${nextEpisode.episodeNumber} '
            'contextMounted=${_playerModalContext.mounted} '
            'scheduler=${WidgetsBinding.instance.schedulerPhase}',
          );
          _showPhoneNextEpisodeCountdown(nextEpisode);
        }
      } else {
        // No next episode, show episode list
        if (widget.useTvControls) {
          _showTvEpisodeMenu();
        } else {
          unawaited(_openEpisodeList());
        }
      }
    } else if (widget.mediaType == MediaType.movie) {
      debugPrint(
        '[MovieRecommendationsDebug][MOVIE_FINISHED] '
        'movieId=${widget.movieMetadata?.movieId} '
        'recommendations=${widget.movieMetadata?.recommendations?.length ?? 0} '
        'ids=${widget.movieMetadata?.recommendations?.map((movie) => movie.movieId).join(',') ?? 'none'}',
      );
      if (widget.movieMetadata?.recommendations != null &&
          widget.movieMetadata!.recommendations!.isNotEmpty) {
        if (widget.useTvControls) {
          debugPrint(
            '[MovieRecommendationsDebug][PRESENT] target=tv_menu',
          );
          _showTvMovieRecommendationsMenu();
        } else {
          // Show recommended movie countdown
          final modalContext = _playerModalContext;
          final navigator = Navigator.of(modalContext, rootNavigator: true);
          debugPrint(
            '[MovieRecommendationsDebug][PRESENT] '
            'target=countdown contextMounted=${modalContext.mounted} '
            'fullscreen=${_betterPlayerController.isFullScreen} '
            'rootCanPop=${navigator.canPop()} '
            'overlay=${identityHashCode(navigator.overlay)}',
          );
          _movieRecommendations.showRecommendedMovieCountdown(
            context: modalContext,
            colors: widget.colors,
            movieMetadata: widget.movieMetadata!,
            onSaveProgress: _handleContentSwitch,
            closePlayer: _closePlayer,
          );
        }
      } else {
        debugPrint(
          '[MovieRecommendationsDebug][PRESENT_SKIPPED] '
          'reason=no_recommendations movieId=${widget.movieMetadata?.movieId}',
        );
      }
    }
  }

  void _handlePlaybackCompleted({required String source}) {
    final value = _betterPlayerController.videoPlayerController?.value;
    debugPrint(
      '[MovieRecommendationsDebug][COMPLETION_ENTER] '
      'source=$source mounted=$mounted preRoll=$_preRollActive '
      'handled=$_playbackCompletionHandled '
      'position=${value?.position.inMilliseconds} '
      'duration=${value?.duration?.inMilliseconds} '
      'playing=${value?.isPlaying} buffering=${value?.isBuffering}',
    );
    if (!mounted) {
      debugPrint(
        '[MovieRecommendationsDebug][COMPLETION_BLOCKED] reason=unmounted',
      );
      return;
    }
    if (_preRollActive) {
      debugPrint(
        '[MovieRecommendationsDebug][COMPLETION_BLOCKED] reason=pre_roll',
      );
      return;
    }
    if (_playbackCompletionHandled) {
      debugPrint(
        '[MovieRecommendationsDebug][COMPLETION_BLOCKED] '
        'reason=already_handled',
      );
      return;
    }
    debugPrint('[Player] Playback completed via $source');
    _playbackCompletionHandled = true;
    _feedbackSession.recordCompletion();
    _stopAnalyticsWatchClock();
    _wellnessTracker.pause();
    _trackPlaybackEvent('finished', value: source);
    _saveWellnessSession(
      completed: true,
      syncImmediately: true,
    );

    // Remove the near-end teaser before presenting the definitive completion
    // action. Native and fallback completion can arrive close together.
    _showNextEpisodeButton = false;
    _hideNextEpisodeOverlay();
    setState(() {
      _activeIntroDbSegment = null;
      _introDbCreditsActive = false;
    });
    _betterPlayerController.setControlsVisibility(false);
    _handleVideoFinished();
  }

  void _openTvMenu(String title, List<BetterPlayerTvMenuItem> items) {
    if (!mounted || !widget.useTvControls || items.isEmpty) return;
    _tvNextEpisodeTimer?.cancel();
    setState(() {
      _tvNextEpisode = null;
      _tvNextEpisodeCountdown = null;
      _tvMenu = _TvPlayerMenuData(title, items);
    });
    _tvControlsController.hide(preserveFocus: true);
  }

  void _closeTvMenu({bool showControls = true}) {
    if (!mounted || _tvMenu == null) return;
    setState(() => _tvMenu = null);
    if (showControls) {
      _tvControlsController.show(restorePreviousFocus: true);
    }
  }

  /// Subtitle timing over the picture, with the controls out of the way so
  /// the captions can be watched against the dialogue.
  void _showTvSubtitleTiming() {
    if (!mounted || !widget.useTvControls) return;
    setState(() => _tvSubtitleTimingOpen = true);
    _tvControlsController.hide(preserveFocus: true);
  }

  void _closeTvSubtitleTiming({bool showControls = true}) {
    if (!mounted || !_tvSubtitleTimingOpen) return;
    setState(() => _tvSubtitleTimingOpen = false);
    if (showControls) {
      _tvControlsController.show(restorePreviousFocus: true);
    }
  }

  bool _handleTvOverlayBack() {
    if (_tvMenu != null) {
      _closeTvMenu();
      return true;
    }
    if (_tvSubtitleTimingOpen) {
      _closeTvSubtitleTiming();
      return true;
    }
    if (_tvNextEpisode != null) {
      _dismissTvNextEpisodePrompt();
      return true;
    }
    return false;
  }

  void _showTvEpisodeMenu() {
    final metadata = widget.tvMetadata;
    final episodes = metadata?.seasonEpisodes;
    if (metadata == null || episodes == null || episodes.isEmpty) return;
    final season = episodes.first.seasonNumber;
    final items = <BetterPlayerTvMenuItem>[
      if ((metadata.allSeasons?.length ?? 0) > 1)
        BetterPlayerTvMenuItem(
          label: tr('select_season'),
          subtitle: tr('season_episodes', namedArgs: {'season': '$season'}),
          icon: PhosphorIcons.stack(),
          showsNext: true,
          onSelected: _showTvSeasonMenu,
        ),
      ...episodes.map(
        (episode) => BetterPlayerTvMenuItem(
          label: '${episode.episodeNumber}. ${episode.episodeName}',
          subtitle: [
            if (episode.runtime != null) '${episode.runtime}m',
            if (episode.voteAverage != null && episode.voteAverage! > 0)
              '★ ${episode.voteAverage!.toStringAsFixed(1)}',
          ].join('  •  '),
          icon: episode.episodeNumber == metadata.episodeNumber &&
                  episode.seasonNumber == metadata.seasonNumber
              ? PhosphorIcons.playCircle(PhosphorIconsStyle.fill)
              : PhosphorIcons.playCircle(),
          selected: episode.episodeNumber == metadata.episodeNumber &&
              episode.seasonNumber == metadata.seasonNumber,
          onSelected: () => _playTvEpisode(episode),
        ),
      ),
    ];
    _openTvMenu(
      tr('season_episodes', namedArgs: {'season': '$season'}),
      items,
    );
  }

  void _showTvSeasonMenu() {
    final metadata = widget.tvMetadata;
    final seasons = metadata?.allSeasons;
    if (metadata == null || seasons == null || seasons.isEmpty) return;
    final browsedSeason = metadata.seasonEpisodes?.isNotEmpty == true
        ? metadata.seasonEpisodes!.first.seasonNumber
        : metadata.seasonNumber;
    _openTvMenu(
      tr('select_season'),
      seasons
          .map(
            (season) => BetterPlayerTvMenuItem(
              label: season.seasonName,
              subtitle: tr(
                'episodes_count',
                namedArgs: {'count': '${season.episodeCount}'},
              ),
              icon: PhosphorIcons.stack(),
              selected: season.seasonNumber == browsedSeason,
              showsNext: true,
              onSelected: () => unawaited(
                _loadTvSeasonEpisodes(season.seasonNumber),
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  Future<void> _loadTvSeasonEpisodes(int seasonNumber) async {
    final metadata = widget.tvMetadata;
    if (metadata == null) return;
    _openTvMenu(
      tr('select_season'),
      [
        BetterPlayerTvMenuItem(
          label: '${tr('loading_episodes')}…',
          icon: PhosphorIcons.spinnerGap(),
          enabled: false,
          onSelected: () {},
        ),
      ],
    );
    final loaded = await _episodeSelection.fetchEpisodesForSeason(
      context,
      seasonNumber,
      metadata,
      widget.colors,
    );
    if (!mounted || _tvMenu == null) return;
    if (loaded) {
      _showTvEpisodeMenu();
    } else {
      _showTvSeasonMenu();
    }
  }

  void _showTvMovieRecommendationsMenu() {
    final metadata = widget.movieMetadata;
    final recommendations = metadata?.recommendations;
    debugPrint(
      '[MovieRecommendationsDebug][TV_MENU_ENTER] '
      'mounted=$mounted movieId=${metadata?.movieId} '
      'recommendations=${recommendations?.length ?? 0}',
    );
    if (metadata == null ||
        recommendations == null ||
        recommendations.isEmpty) {
      debugPrint(
        '[MovieRecommendationsDebug][TV_MENU_SKIPPED] '
        'reason=missing_metadata_or_recommendations',
      );
      return;
    }
    _openTvMenu(
      tr('recommended_movies'),
      recommendations
          .map(
            (movie) => BetterPlayerTvMenuItem(
              label: movie.title,
              subtitle: [
                if (movie.releaseDate?.isNotEmpty == true)
                  movie.releaseDate!.split('-').first,
                if (movie.voteAverage != null && movie.voteAverage! > 0)
                  '★ ${movie.voteAverage!.toStringAsFixed(1)}',
              ].join('  •  '),
              icon: PhosphorIcons.filmSlate(),
              onSelected: () => _playTvMovie(movie),
            ),
          )
          .toList(growable: false),
    );
  }

  void _showTvProviderMenu() {
    final providers = (widget.availableProviders ?? const <VideoProvider>[])
        .where((provider) =>
            provider.codeName != VideoProvider.unifiedSources.codeName &&
            provider.supportsMedia(_playbackCacheIdentity) &&
            (_rawVideoLinksByProvider[provider.codeName]?.isNotEmpty != true))
        .toList(growable: false);
    final streamLinks = _unifiedStreamLinks;
    if (providers.isEmpty &&
        streamLinks.isEmpty &&
        _qualityCatalogEntries.isEmpty) {
      return;
    }
    final items = <BetterPlayerTvMenuItem>[
      // Keep the TV control bar itself unchanged. The cross-provider quality
      // list is reachable from the existing Switch Provider menu instead.
      BetterPlayerTvMenuItem(
        label: tr('player_quality'),
        subtitle: _qualityCatalogStatus(_qualityCatalogEntries.length),
        icon: PhosphorIcons.highDefinition(),
        showsNext: true,
        onSelected: _showTvQualityMenu,
      ),
      for (final link in streamLinks)
        BetterPlayerTvMenuItem(
          label: _streamServerName(link),
          subtitle: _streamSubtitle(link),
          icon: _isActiveUnifiedStream(link)
              ? PhosphorIcons.playCircle(PhosphorIconsStyle.fill)
              : PhosphorIcons.hardDrives(),
          selected: _isActiveUnifiedStream(link),
          enabled: !_isSwitchingProvider,
          onSelected: _isActiveUnifiedStream(link)
              ? _closeTvMenu
              : () => unawaited(
                    _activateUnifiedStream(
                      link,
                      refreshMenu: () {
                        if (_tvMenu != null) _showTvProviderMenu();
                      },
                      closeMenu: _closeTvMenu,
                    ),
                  ),
        ),
      for (final provider in providers)
        () {
          final selected = provider.codeName == _currentProviderCode;
          final loading = _loadingProviders.contains(provider.codeName);
          final error = _providerErrors[provider.codeName];
          final content = provider.content?.trim();
          return BetterPlayerTvMenuItem(
            label: provider.displayName,
            subtitle: loading
                ? tr('loading_video_sources')
                : error ??
                    [
                      if (selected) tr('currently_playing'),
                      if (content?.isNotEmpty == true) content!,
                      if (!selected && content?.isNotEmpty != true)
                        tr('video_source'),
                    ].join('  •  '),
            icon: error != null
                ? PhosphorIcons.warningCircle()
                : selected
                    ? PhosphorIcons.playCircle(PhosphorIconsStyle.fill)
                    : PhosphorIcons.hardDrives(),
            selected: selected,
            enabled: !loading && !_isSwitchingProvider,
            onSelected: selected
                ? _closeTvMenu
                : () => _switchToProvider(
                      provider.codeName,
                      refreshMenu: () {
                        if (_tvMenu != null) _showTvProviderMenu();
                      },
                      closeMenu: _closeTvMenu,
                    ),
          );
        }(),
    ];
    _openTvMenu(
      tr('select_provider'),
      items,
    );
  }

  /// Remote-friendly view of the same cross-provider quality catalogue used
  /// on mobile. It leaves the existing TV control bar and provider-switch
  /// behavior intact, while making every discovered stream selectable.
  void _showTvQualityMenu() {
    if (!mounted || !widget.useTvControls) return;

    final allEntries = _qualityCatalogEntries;
    final hasAdaptiveSource = _activeVideoFormats?.values.any((format) =>
            format == BetterPlayerVideoFormat.hls ||
            format == BetterPlayerVideoFormat.dash) ==
        true ||
        allEntries.any((entry) =>
            entry.isAdaptive && entry.link.url == _activeStreamUrl);
    final showAutoTrack = hasAdaptiveSource;
    final entries = allEntries
        .where((entry) =>
            !(showAutoTrack &&
                entry.isAdaptive &&
                entry.adaptiveTargetHeight == null &&
                entry.link.url == _activeStreamUrl &&
                entry.providerCode == _currentProviderCode))
        .toList(growable: false);
    final catalogTrackHeights = allEntries
        .where((entry) =>
            entry.isAdaptive &&
            entry.link.url == _activeStreamUrl &&
            entry.providerCode == _currentProviderCode &&
            entry.adaptiveTargetHeight != null)
        .map((entry) => entry.adaptiveTargetHeight!)
        .toSet();
    final adaptiveTracks = _betterPlayerController.betterPlayerAsmsTracks
        .where((track) =>
            (track.height ?? 0) > 0 &&
            !catalogTrackHeights.contains(track.height))
        .toList(growable: false)
      ..sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));

    final items = <BetterPlayerTvMenuItem>[];
    if (showAutoTrack) {
      final currentTrack = _betterPlayerController.betterPlayerAsmsTrack;
      final defaultTrack = BetterPlayerAsmsTrack.defaultTrack();
      final isAuto = currentTrack == null || currentTrack.id == defaultTrack.id;
      items.add(
        BetterPlayerTvMenuItem(
          label: 'Auto',
          subtitle: _activeStreamServerName ?? _currentProviderName(),
          icon: isAuto
              ? PhosphorIcons.playCircle(PhosphorIconsStyle.fill)
              : PhosphorIcons.highDefinition(),
          selected: isAuto,
          enabled: !isAuto && !_isSwitchingProvider,
          onSelected: () {
            _betterPlayerController.setTrack(defaultTrack);
            _closeTvMenu();
          },
        ),
      );
    }

    for (final entry in entries) {
      final currentTrack = _betterPlayerController.betterPlayerAsmsTrack;
      final isCurrentUrl = entry.link.url == _activeStreamUrl &&
          entry.providerCode == _currentProviderCode;
      final selected = entry.isAdaptive
          ? isCurrentUrl &&
              (entry.adaptiveTargetHeight == null
                  ? currentTrack == null ||
                      currentTrack.id == BetterPlayerAsmsTrack.defaultTrack().id
                  : currentTrack?.height == entry.adaptiveTargetHeight)
          : isCurrentUrl;
      items.add(
        BetterPlayerTvMenuItem(
          label: '${entry.qualityLabel} · ${_streamServerName(entry.link)}',
          subtitle: _streamTechnicalDetails(entry.link),
          icon: selected
              ? PhosphorIcons.playCircle(PhosphorIconsStyle.fill)
              : PhosphorIcons.highDefinition(),
          selected: selected,
          enabled: !selected && !_isSwitchingProvider,
          onSelected: () => unawaited(
            _activateQualityCatalogEntry(
              entry,
              refreshMenu: () {
                if (_tvMenu != null) _showTvQualityMenu();
              },
              closeMenu: _closeTvMenu,
            ),
          ),
        ),
      );
    }

    for (final track in adaptiveTracks) {
      final current = _betterPlayerController.betterPlayerAsmsTrack;
      final selected = current?.id == track.id && current != null;
      final height = track.height!;
      final dimensions = track.width == null
          ? '${height}p'
          : '${track.width}×${height}';
      items.add(
        BetterPlayerTvMenuItem(
          label: '${height}p',
          subtitle: dimensions,
          icon: selected
              ? PhosphorIcons.playCircle(PhosphorIconsStyle.fill)
              : PhosphorIcons.highDefinition(),
          selected: selected,
          enabled: !selected && !_isSwitchingProvider,
          onSelected: () {
            _betterPlayerController.setTrack(track);
            _closeTvMenu();
          },
        ),
      );
    }

    if (items.isEmpty) {
      items.add(
        BetterPlayerTvMenuItem(
          label: tr('loading_video_sources'),
          subtitle: _qualityCatalogStatus(0),
          icon: PhosphorIcons.spinnerGap(),
          enabled: false,
          onSelected: () {},
        ),
      );
    }

    _openTvMenu(tr('player_quality'), items);
  }

  List<RegularVideoLinks> get _unifiedStreamLinks =>
      _rawVideoLinksByProvider[VideoProvider.unifiedSources.codeName]
          ?.where((link) => link.url?.trim().isNotEmpty == true)
          .toList(growable: false) ??
      const <RegularVideoLinks>[];

  String _serverNameForUrl(String url, {String? providerCode}) {
    final links = providerCode == null
        ? _rawVideoLinksByProvider.values.expand((items) => items)
        : (_rawVideoLinksByProvider[providerCode] ?? const <RegularVideoLinks>[]);
    for (final link in links) {
      if (link.url == url) {
        final name = link.server?.trim();
        if (name != null && name.isNotEmpty) return name;
      }
    }
    return providerCode == null
        ? tr('tv_current_provider')
        : _providerDisplayName(providerCode);
  }

  String _streamServerName(RegularVideoLinks link) {
    final value = link.server?.trim();
    return value == null || value.isEmpty
        ? tr('tv_current_provider')
        : value;
  }

  String _streamQualityName(RegularVideoLinks link) {
    if (link.isAdaptive && link.availableHeights.length > 1) {
      final heights = link.availableHeights.toSet().toList()..sort((a, b) => b.compareTo(a));
      return 'Adaptive · ${heights.map((height) => '${height}p').join(' / ')}';
    }
    final value = link.quality?.trim();
    if (value == null || value.isEmpty) return tr('not_available');
    final server = link.server?.trim();
    if (server == null || server.isEmpty) return value;
    return value
        .split(' · ')
        .where((part) => part.trim().isNotEmpty && part.trim() != server)
        .join(' · ');
  }

  String _streamFormatName(RegularVideoLinks link) {
    if (link.isM3U8 == true) return 'HLS';
    if (link.isDash == true) return 'DASH';
    final path = Uri.tryParse(link.url ?? '')?.path.toLowerCase() ?? '';
    if (path.endsWith('.m3u8')) return 'HLS';
    if (path.endsWith('.mpd')) return 'DASH';
    if (path.endsWith('.mp4') || path.endsWith('.m4v')) return 'MP4';
    if (path.endsWith('.webm')) return 'WebM';
    return tr('video_source');
  }

  String _streamSubtitle(RegularVideoLinks link) {
    final details = <String>[
      _streamQualityName(link),
      _streamFormatName(link),
      if (link.headers?.isNotEmpty == true) 'Headers',
    ].where((value) => value.trim().isNotEmpty).toList(growable: false);
    return details.join('  •  ');
  }

  String _streamTechnicalDetails(RegularVideoLinks link) => [
        _streamFormatName(link),
        if (link.headers?.isNotEmpty == true) 'Request headers',
      ].join('  •  ');

  bool _isActiveUnifiedStream(RegularVideoLinks link) =>
      link.url != null &&
      link.url == _activeStreamUrl &&
      (link.providerCode == _currentProviderCode ||
          _currentProviderCode == VideoProvider.unifiedSources.codeName);

  EpisodeMetadata? get _nextTvEpisode {
    final metadata = widget.tvMetadata;
    final episodes = metadata?.seasonEpisodes;
    if (metadata == null || episodes == null || episodes.isEmpty) return null;
    final currentIndex = episodes.indexWhere(
      (episode) =>
          episode.episodeNumber == metadata.episodeNumber &&
          episode.seasonNumber == metadata.seasonNumber,
    );
    if (currentIndex < 0 || currentIndex >= episodes.length - 1) return null;
    return episodes[currentIndex + 1];
  }

  /// Netflix's pace: a longer count at the credits, where the episode is
  /// still playing, and a short one once it has ended.
  static const _creditsCountdown = 15;
  static const _endCountdown = 10;

  void _showTvNextEpisodePrompt({
    required bool startCountdown,
    bool atCredits = false,
  }) {
    final nextEpisode = _nextTvEpisode;
    _logNextEpisodeState(
      startCountdown ? 'tv_countdown_requested' : 'tv_prompt_requested',
      force: true,
    );
    if (!mounted || nextEpisode == null) {
      debugPrint(
        '[NextEpisodeDebug][tv_prompt_skipped] mounted=$mounted '
        'nextEpisode=${nextEpisode == null ? 'null' : 'available'}',
      );
      return;
    }
    _tvNextEpisodeTimer?.cancel();
    final seconds = atCredits ? _creditsCountdown : _endCountdown;
    setState(() {
      _tvMenu = null;
      _tvSubtitleTimingOpen = false;
      _tvNextEpisode = nextEpisode;
      _tvNextEpisodeAtCredits = atCredits;
      _tvNextEpisodeCountdownTotal = seconds;
      _tvNextEpisodeCountdown = startCountdown ? seconds : null;
    });
    _tvControlsController.hide(preserveFocus: true);
    if (!startCountdown) return;
    _tvNextEpisodeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _tvNextEpisode == null) {
        timer.cancel();
        return;
      }
      final countdown = _tvNextEpisodeCountdown ?? 0;
      if (countdown <= 1) {
        timer.cancel();
        unawaited(_playTvEpisode(nextEpisode));
      } else {
        setState(() => _tvNextEpisodeCountdown = countdown - 1);
      }
    });
  }

  void _clearTvNextEpisodePrompt({bool showControls = true}) {
    _tvNextEpisodeTimer?.cancel();
    _tvNextEpisodeTimer = null;
    if (!mounted || _tvNextEpisode == null) return;
    setState(() {
      _tvNextEpisode = null;
      _tvNextEpisodeCountdown = null;
    });
    if (showControls) {
      _tvControlsController.show(restorePreviousFocus: true);
    }
  }

  void _dismissTvNextEpisodePrompt() {
    _nextEpisodeButtonDismissed = true;
    _showNextEpisodeButton = false;
    _clearTvNextEpisodePrompt();
  }

  Future<void> _startContent(Future<void> Function() action) async {
    if (_startingContent || !mounted || _adBlockStopped) return;
    setState(() => _startingContent = true);
    _nextEpisodeOverlay?.markNeedsBuild();
    // Fullscreen controls live on a separate route. Show feedback above that
    // route too while preparing the next content for navigation.
    _contentSwitchLoading = OverlayEntry(
      builder: (_) => const Positioned.fill(
        child: AbsorbPointer(
          child: ColoredBox(
            color: Color(0x66000000),
            child: Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          ),
        ),
      ),
    );
    Navigator.of(context, rootNavigator: true)
        .overlay!
        .insert(_contentSwitchLoading!);
    try {
      await action();
    } finally {
      _hideContentSwitchLoading();
      if (mounted) {
        setState(() => _startingContent = false);
        _nextEpisodeOverlay?.markNeedsBuild();
      }
    }
  }

  void _hideContentSwitchLoading() {
    _contentSwitchLoading?.remove();
    _contentSwitchLoading?.dispose();
    _contentSwitchLoading = null;
  }

  Future<void> _playTvEpisode(EpisodeMetadata episode) =>
      _startContent(() async {
        _tvNextEpisodeTimer?.cancel();
        if (mounted) {
          setState(() {
            _tvMenu = null;
            _tvSubtitleTimingOpen = false;
          });
        }
        _handleContentSwitch();
        if (!mounted) return;
        _hideContentSwitchLoading();
        _hideNextEpisodeOverlay();
        setState(() {
          _tvNextEpisode = null;
          _tvNextEpisodeCountdown = null;
        });
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (context) => AdsterraPlaybackGate.buildLoader(context,
                television: widget.useTvControls,
                content: _seriesAdContent,
                builder: (context) => TVVideoLoader(
                      download: false,
                      useTvPlayer: widget.useTvControls,
                      onTvPlayerExit: widget.onTvPlayerExit,
                      metadata: _metadataForTvEpisode(episode),
                      adStage: PlaybackAdStage.episodeSwitch,
                    )),
          ),
        );
      });

  Future<void> _playTvMovie(MovieRecommendation movie) =>
      _startContent(() async {
        if (mounted) setState(() => _tvMenu = null);
        _handleContentSwitch();
        if (!mounted) return;
        _hideContentSwitchLoading();
        _hideNextEpisodeOverlay();
        final metadata = MovieStreamMetadata(
          movieId: movie.movieId,
          movieName: movie.title,
          posterPath: movie.posterPath,
          backdropPath: movie.backdropPath,
          releaseDate: movie.releaseDate,
          releaseYear: movie.releaseDate == null
              ? null
              : DateTime.tryParse(movie.releaseDate!)?.year,
          isAdult: false,
          elapsed: 0,
          genreIds: movie.genreIds,
          originalLanguage: movie.originalLanguage,
        );
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (context) => AdsterraPlaybackGate.buildLoader(context,
                television: widget.useTvControls,
                content: AdContent(
                    series: false, id: movie.movieId, genreIds: movie.genreIds),
                builder: (context) => MovieVideoLoader(
                      download: false,
                      useTvPlayer: widget.useTvControls,
                      onTvPlayerExit: widget.onTvPlayerExit,
                      metadata: metadata,
                      adStage: PlaybackAdStage.movieSwitch,
                    )),
          ),
        );
      });

  /// The series this player is in, for the ad rules of its next episode.
  AdContent? get _seriesAdContent {
    final metadata = widget.tvMetadata;
    final id = metadata?.tvId;
    return id == null
        ? null
        : AdContent(series: true, id: id, genreIds: metadata?.genreIds);
  }

  TVStreamMetadata _metadataForTvEpisode(EpisodeMetadata episode) {
    final current = widget.tvMetadata!;
    return TVStreamMetadata(
      elapsed: null,
      episodeId: episode.episodeId,
      episodeName: episode.episodeName,
      episodeNumber: episode.episodeNumber,
      posterPath: current.posterPath,
      backdropPath: episode.stillPath ?? current.backdropPath,
      seasonNumber: episode.seasonNumber,
      seriesName: current.seriesName,
      tvId: current.tvId,
      airDate: episode.airDate,
      genres: current.genres,
      genreIds: current.genreIds,
      isAnime: current.isAnime,
      languages: current.languages,
      countries: current.countries,
      seasonEpisodes: current.seasonEpisodes,
      allSeasons: current.allSeasons,
    );
  }

  void _showProviderSwitcher() {
    showPlayerSheet<void>(
      context: context,
      builder: (sheetContext) => ValueListenableBuilder<int>(
        valueListenable: _streamCatalogRevision,
        builder: (context, revision, _) {
          final streamLinks = _unifiedStreamLinks;
          final providers = (widget.availableProviders ?? const <VideoProvider>[])
              .where((provider) =>
                  provider.codeName != VideoProvider.unifiedSources.codeName &&
                  provider.supportsMedia(_playbackCacheIdentity) &&
                  (_rawVideoLinksByProvider[provider.codeName]?.isNotEmpty != true))
              .toList(growable: false);
          final itemCount = streamLinks.length + providers.length;
          if (itemCount == 0) return const SizedBox.shrink();
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: .72,
            minChildSize: .45,
            maxChildSize: .96,
            snap: true,
            builder: (context, scrollController) => PlayerSheetScaffold(
              title: tr('select_provider'),
              subtitle: '$itemCount ${tr('video_source')}',
              actions: [
                PlayerSheetAction(
                  icon: PhosphorIcons.x(),
                  tooltip: tr('close'),
                  onPressed: () => Navigator.pop(sheetContext),
                ),
              ],
              child: ListView.separated(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                itemCount: itemCount,
                separatorBuilder: (_, __) => const SizedBox(height: 2),
                itemBuilder: (context, index) {
                  if (index < streamLinks.length) {
                    final link = streamLinks[index];
                    final selected = _isActiveUnifiedStream(link);
                    return PlayerChoiceCard(
                      kicker: selected
                          ? tr('player_now_playing')
                          : 'UNIFIED SOURCE',
                      title: _streamServerName(link),
                      selected: selected,
                      subtitle: _streamQualityName(link),
                      description: _streamTechnicalDetails(link),
                      trailing: _isSwitchingProvider
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : selected
                              ? Icon(
                                  PhosphorIcons.checkCircle(
                                    PhosphorIconsStyle.fill,
                                  ),
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : null,
                      onTap: selected || _isSwitchingProvider
                          ? null
                          : () => _activateUnifiedStream(
                                link,
                                refreshMenu: () {},
                                closeMenu: () {
                                  if (sheetContext.mounted) {
                                    Navigator.pop(sheetContext);
                                  }
                                },
                              ),
                    );
                  }

                  final provider = providers[index - streamLinks.length];
                  final selected = provider.codeName == _currentProviderCode;
                  final loading = _loadingProviders.contains(provider.codeName);
                  final error = _providerErrors[provider.codeName];
                  final content = provider.content?.trim();
                  return PlayerChoiceCard(
                    kicker: selected ? tr('player_now_playing') : null,
                    title: provider.displayName,
                    selected: selected,
                    subtitle: loading
                        ? tr('loading_video_sources')
                        : error ??
                            (content?.isNotEmpty == true
                                ? content
                                : tr('video_source')),
                    trailing: loading
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : error == null
                            ? null
                            : Icon(
                                PhosphorIcons.warningCircle(),
                                color: Theme.of(context).colorScheme.error,
                              ),
                    onTap: selected || loading || _isSwitchingProvider
                        ? null
                        : () => _switchToProvider(
                              provider.codeName,
                              refreshMenu: () {},
                              closeMenu: () {
                                if (sheetContext.mounted) {
                                  Navigator.pop(sheetContext);
                                }
                              },
                            ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _scanAdaptiveQualityLinks(
    Iterable<RegularVideoLinks> candidates,
  ) async {
    final adaptive = candidates.where((link) {
      final uri = Uri.tryParse(link.url?.trim() ?? '');
      final path = uri?.path.toLowerCase() ?? '';
      final quality = link.quality?.trim().toLowerCase() ?? '';
      return link.isAdaptive ||
          link.availableHeights.isNotEmpty ||
          link.isM3U8 == true ||
          link.isDash == true ||
          path.endsWith('.m3u8') ||
          path.endsWith('.mpd') ||
          quality.startsWith('auto') ||
          quality.startsWith('adaptive') ||
          quality.startsWith('master');
    });
    final pending = <RegularVideoLinks>[];
    for (final link in adaptive) {
      final url = link.url?.trim() ?? '';
      if (url.isEmpty) continue;
      final headers = (link.headers ?? const <String, String>{}).entries.toList()
        ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
      final signature = '$url|${headers.map((e) => '${e.key}:${e.value}').join('|')}';
      if (_adaptiveQualityScansStarted.add(signature)) {
        pending.add(link);
        _adaptiveQualityScansInProgress.add(signature);
      }
    }

    Future<void> scanOne(RegularVideoLinks link) async {
      final url = link.url?.trim() ?? '';
      if (url.isEmpty) return;
      final headers = (link.headers ?? const <String, String>{}).entries.toList()
        ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
      final signature = '$url|${headers.map((e) => '${e.key}:${e.value}').join('|')}';
      try {
        final heights = await _adaptiveQualityScanner.scan(link);
        final before = link.availableHeights.toSet();
        final wasAdaptive = link.isAdaptive;
        link.availableHeights = heights;
        if (heights.isNotEmpty) link.isAdaptive = true;
        widget.providerScanSession?.reportAdaptiveQualityHeights(heights);
        if (heights.toSet().difference(before).isNotEmpty ||
            (heights.isNotEmpty && !wasAdaptive)) {
          _notifyStreamCatalogChanged();
          debugPrint(
            '[PlaybackQuality][MANIFEST] provider=${link.providerCode} '
            'server=${link.server} heights=${heights.join(',')} url=$url',
          );
          if (mounted) setState(() {});
          if (_hasPlaybackInitialized) unawaited(_savePlaybackCache());
        }
      } catch (error) {
        debugPrint('[PlaybackQuality][MANIFEST_FAILED] url=$url error=$error');
      } finally {
        _adaptiveQualityScansInProgress.remove(signature);
        if (!link.isAdaptive && link.availableHeights.isEmpty) {
          // A URL that yielded no manifest heights may be temporarily blocked.
          // Keep it eligible for an explicit provider reload/retry.
          _adaptiveQualityScansStarted.remove(signature);
        }
        if (mounted) {
          _notifyStreamCatalogChanged();
          setState(() {});
        }
      }
    }

    for (var offset = 0; offset < pending.length; offset += 3) {
      final end = (offset + 3).clamp(0, pending.length).toInt();
      await Future.wait(pending.sublist(offset, end).map(scanOne));
    }
  }

  List<QualityCatalogEntry> get _qualityCatalogEntries =>
      PlaybackQualityCatalog.collect(
        linksByProvider: _rawVideoLinksByProvider,
      );

  String _qualityCatalogStatus(int optionCount) {
    final scan = widget.providerScanSession;
    if (scan == null) return '$optionCount ${tr('video_source')}';
    if (scan.qualityTargetReached) {
      if (scan.inFlightProviderCount > 0 ||
          _adaptiveQualityScansInProgress.isNotEmpty) {
        return tr('quality_scan_finishing_inflight', namedArgs: {
          'count': '${scan.inFlightProviderCount + _adaptiveQualityScansInProgress.length}',
          'completed': '${scan.completedProviderCount}',
        });
      }
      return tr('quality_scan_target_reached', namedArgs: {
        'completed': '${scan.completedProviderCount}',
      });
    }
    if (scan.isCompleted && _adaptiveQualityScansInProgress.isNotEmpty) {
      return 'Reading adaptive stream qualities · ${_adaptiveQualityScansInProgress.length}';
    }
    if (scan.isCompleted) {
      final missing = <int>[480, 720, 1080]
          .where((height) => !scan.availableQualityHeights.contains(height))
          .toList()
        ..sort((a, b) => b.compareTo(a));
      return tr('quality_scan_complete_missing', namedArgs: {
        'missing': missing.map((height) => '${height}p').join(' · '),
        'completed': '${scan.completedProviderCount}',
      });
    }
    return tr('quality_scan_searching', namedArgs: {
      'completed': '${scan.completedProviderCount}',
      'total': '${scan.totalEligibleProviderCount}',
    });
  }

  void _showQualitySwitcher() {
    showPlayerSheet<void>(
      context: context,
      builder: (sheetContext) => ValueListenableBuilder<int>(
        valueListenable: _streamCatalogRevision,
        builder: (context, revision, _) {
          final allEntries = _qualityCatalogEntries;
          final hasAdaptiveSource = _activeVideoFormats?.values.any((format) =>
                  format == BetterPlayerVideoFormat.hls ||
                  format == BetterPlayerVideoFormat.dash) ==
              true ||
              allEntries.any((entry) => entry.isAdaptive &&
                  entry.link.url == _activeStreamUrl);
          final showAutoTrack = hasAdaptiveSource;
          final entries = allEntries.where((entry) =>
              !(showAutoTrack &&
                  entry.isAdaptive &&
                  entry.adaptiveTargetHeight == null &&
                  entry.link.url == _activeStreamUrl &&
                  entry.providerCode == _currentProviderCode)).toList(growable: false);
          final catalogTrackHeights = allEntries
              .where((entry) => entry.isAdaptive &&
                  entry.link.url == _activeStreamUrl &&
                  entry.providerCode == _currentProviderCode &&
                  entry.adaptiveTargetHeight != null)
              .map((entry) => entry.adaptiveTargetHeight!)
              .toSet();
          final adaptiveTracks = _betterPlayerController.betterPlayerAsmsTracks
              .where((track) => (track.height ?? 0) > 0 &&
                  !catalogTrackHeights.contains(track.height))
              .toList(growable: false)
            ..sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
          final adaptiveOffset = showAutoTrack ? 1 : 0;
          final entriesEnd = adaptiveOffset + entries.length;
          final itemCount = entriesEnd + adaptiveTracks.length;
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: .68,
            minChildSize: .38,
            maxChildSize: .94,
            snap: true,
            builder: (context, scrollController) => PlayerSheetScaffold(
              title: tr('player_quality'),
              subtitle: _qualityCatalogStatus(itemCount),
              actions: [
                PlayerSheetAction(
                  icon: PhosphorIcons.x(),
                  tooltip: tr('close'),
                  onPressed: () => Navigator.pop(sheetContext),
                ),
              ],
              child: itemCount == 0
                  ? Center(child: Text(tr('loading_video_sources')))
                  : ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                      itemCount: itemCount,
                      separatorBuilder: (_, __) => const SizedBox(height: 2),
                      itemBuilder: (context, index) {
                        if (showAutoTrack && index == 0) {
                          final defaultTrack = BetterPlayerAsmsTrack.defaultTrack();
                          final selectedTrack =
                              _betterPlayerController.betterPlayerAsmsTrack;
                          final isAuto = selectedTrack == null ||
                              selectedTrack.id == defaultTrack.id;
                          final currentHeight = _betterPlayerController
                              .videoPlayerController?.value.size?.height.round();
                          return PlayerChoiceCard(
                            kicker: isAuto ? tr('player_now_playing') : 'ADAPTIVE',
                            title: 'Auto',
                            selected: isAuto,
                            subtitle: currentHeight == null
                                ? tr('quality_adaptive')
                                : '${currentHeight}p · ${tr('player_quality_auto_note')}',
                            description: _activeStreamServerName ??
                                _currentProviderName(),
                            onTap: isAuto || _isSwitchingProvider
                                ? null
                                : () {
                                    _betterPlayerController.setTrack(defaultTrack);
                                    if (sheetContext.mounted) {
                                      Navigator.pop(sheetContext);
                                    }
                                  },
                          );
                        }

                        if (index >= adaptiveOffset && index < entriesEnd) {
                          final entry = entries[index - adaptiveOffset];
                          final currentTrack =
                              _betterPlayerController.betterPlayerAsmsTrack;
                          final isCurrentUrl = entry.link.url == _activeStreamUrl &&
                              entry.providerCode == _currentProviderCode;
                          final selected = entry.isAdaptive
                              ? isCurrentUrl &&
                                  (entry.adaptiveTargetHeight == null
                                      ? currentTrack == null ||
                                          currentTrack.id ==
                                              BetterPlayerAsmsTrack.defaultTrack().id
                                      : currentTrack?.height ==
                                          entry.adaptiveTargetHeight)
                              : isCurrentUrl;
                          return PlayerChoiceCard(
                            kicker: entry.qualityLabel,
                            title: _streamServerName(entry.link),
                            selected: selected,
                            subtitle: _streamTechnicalDetails(entry.link),
                            description: entry.link.expiresAt == null
                                ? null
                                : 'Link expires ${entry.link.expiresAt!.toLocal()}',
                            trailing: selected
                                ? Icon(
                                    PhosphorIcons.checkCircle(
                                      PhosphorIconsStyle.fill,
                                    ),
                                    color: Theme.of(context).colorScheme.primary,
                                  )
                                : null,
                            onTap: selected || _isSwitchingProvider
                                ? null
                                : () => unawaited(
                                      _activateQualityCatalogEntry(
                                        entry,
                                        refreshMenu: () {},
                                        closeMenu: () {
                                          if (sheetContext.mounted) {
                                            Navigator.pop(sheetContext);
                                          }
                                        },
                                      ),
                                    ),
                          );
                        }

                        final trackIndex = index - entriesEnd;
                        final track = adaptiveTracks[trackIndex];
                        final current =
                            _betterPlayerController.betterPlayerAsmsTrack;
                        final selected = current?.id == track.id && current != null;
                        final height = track.height!;
                        final dimensions = track.width == null
                            ? '${height}p'
                            : '${track.width}×${height}';
                        return PlayerChoiceCard(
                          kicker: selected ? tr('player_now_playing') : 'ADAPTIVE TRACK',
                          title: '${height}p',
                          selected: selected,
                          subtitle: dimensions,
                          description: _activeStreamServerName ??
                              _currentProviderName(),
                          onTap: selected || _isSwitchingProvider
                              ? null
                              : () {
                                  _betterPlayerController.setTrack(track);
                                  if (sheetContext.mounted) {
                                    Navigator.pop(sheetContext);
                                  }
                                },
                        );
                      },
                    ),
            ),
          );
        },
      ),
    );
  }

  Future<bool> _activateQualityCatalogEntry(
    QualityCatalogEntry entry, {
    required VoidCallback refreshMenu,
    required VoidCallback closeMenu,
  }) async {
    final url = entry.link.url;
    final targetHeight = entry.adaptiveTargetHeight;
    if (entry.isAdaptive && url != null && url == _activeStreamUrl) {
      if (targetHeight == null) {
        _betterPlayerController.setTrack(BetterPlayerAsmsTrack.defaultTrack());
        closeMenu();
        return true;
      }
      final selected = await _selectAdaptiveTrackHeight(
        targetHeight,
        expectedUrl: url,
      );
      if (selected) closeMenu();
      return selected;
    }

    final switched = await _activateUnifiedStream(
      entry.link,
      refreshMenu: refreshMenu,
      closeMenu: closeMenu,
    );
    if (!switched) return false;
    if (entry.isAdaptive && targetHeight != null) {
      return _selectAdaptiveTrackHeight(
        targetHeight,
        expectedUrl: url,
      );
    }
    return true;
  }

  Future<bool> _selectAdaptiveTrackHeight(
    int height, {
    required String? expectedUrl,
  }) async {
    // The source switch completes before HLS/DASH tracks are always available.
    // Wait briefly for BetterPlayer to publish its renditions; this is only
    // executed after the user explicitly chooses a quality row.
    for (var attempt = 0; attempt < 32; attempt++) {
      if (!mounted || _adBlockStopped || expectedUrl != _activeStreamUrl) {
        return false;
      }
      final track = _betterPlayerController.betterPlayerAsmsTracks
          .where((candidate) => candidate.height == height)
          .firstOrNull;
      if (track != null) {
        _betterPlayerController.setTrack(track);
        debugPrint(
          '[PlaybackQuality][USER_VARIANT_SELECTED] height=${height}p '
          'provider=$_currentProviderCode url=$expectedUrl',
        );
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    debugPrint(
      '[PlaybackQuality][VARIANT_NOT_EXPOSED] height=${height}p url=$expectedUrl',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('The ${height}p track is not available in this stream.')),
      );
    }
    return false;
  }

  /// Selects one concrete link from a provider while preserving every
  /// mirror's resolution, format and request-header metadata.
  Future<bool> _activateUnifiedStream(
    RegularVideoLinks requestedLink, {
    required VoidCallback refreshMenu,
    required VoidCallback closeMenu,
    Duration? resumeAt,
    bool resumePlayback = false,
  }) {
    final owner = requestedLink.providerCode;
    final providerCode = owner != null &&
            _rawVideoLinksByProvider.containsKey(owner)
        ? owner
        : VideoProvider.unifiedSources.codeName;
    return _activateProviderStream(
      providerCode,
      requestedLink,
      refreshMenu: refreshMenu,
      closeMenu: closeMenu,
      resumeAt: resumeAt,
      resumePlayback: resumePlayback,
    );
  }

  Future<bool> _activateProviderStream(
    String providerCode,
    RegularVideoLinks requestedLink, {
    required VoidCallback refreshMenu,
    required VoidCallback closeMenu,
    Duration? resumeAt,
    bool resumePlayback = false,
  }) async {
    if (_adBlockStopped || _isSwitchingProvider) return false;

    final links = List<RegularVideoLinks>.of(
      _rawVideoLinksByProvider[providerCode] ?? const <RegularVideoLinks>[],
    );
    final index = links.indexWhere((link) =>
        identical(link, requestedLink) ||
        (link.url == requestedLink.url &&
            link.server == requestedLink.server &&
            link.quality == requestedLink.quality));
    final requestedUrl = requestedLink.url?.trim();
    if (index < 0 || requestedUrl == null || requestedUrl.isEmpty) {
      return false;
    }

    final keys = VideoUtils.videoSourceKeys(links);
    if (index >= keys.length) return false;
    final selectedKey = keys[index];
    final sources = VideoUtils.reverseVideoQualityMap(
      VideoUtils.convertVideoLinksToMap(links),
    );
    if (!sources.containsKey(selectedKey)) return false;
    final formats = VideoUtils.reverseVideoQualityMap(
      VideoUtils.convertVideoFormatsToMap(links),
    );
    final headers = VideoUtils.reverseVideoQualityMap(
      VideoUtils.convertVideoHeadersToMap(links),
    );
    final sizeTokens = VideoUtils.reverseVideoQualityMap(
      VideoUtils.convertVideoSizeTokensToMap(links),
    );
    final linkUrl = requestedUrl;
    final providerSubtitles = _buildProviderSubtitles(
      _subtitleLinksByProvider[providerCode] ?? const <RegularSubtitleLinks>[],
    );
    // Provider subtitle tracks belong to the newly selected provider. Do
    // not carry stale network subtitle URLs from the previous provider; local
    // external/user subtitles are appended independently by _buildDataSource.
    final selectedSubtitles = providerSubtitles;
    final providerName = _streamServerName(requestedLink);
    final analyticsStopwatch = Stopwatch()..start();
    final position = resumeAt ??
        _betterPlayerController.videoPlayerController?.value.position ??
        Duration.zero;
    final wasPlaying = resumePlayback ||
        _betterPlayerController.videoPlayerController?.value.isPlaying == true;
    final previousDataSource = _betterPlayerController.betterPlayerDataSource;
    var replacementStarted = false;
    var switched = false;

    _feedbackSourceSwitches++;
    setState(() {
      _isSwitchingProvider = true;
      _loadingProviders.add(providerCode);
      _providerErrors.remove(providerCode);
    });
    refreshMenu();

    try {
      await _betterPlayerController.pause();
      if (!mounted || _adBlockStopped) return false;
      replacementStarted = true;
      _preRollActive = false;
      _startupPlaybackWatchStartedAt = DateTime.now();
      _startupTimeoutLogged = false;
      await _betterPlayerController.setupDataSource(
        _buildDataSource(
          sources: sources,
          subtitles: selectedSubtitles,
          videoFormats: formats,
          videoHeaders: headers,
          selectedResolution: selectedKey,
        ),
        initialPosition: position,
      );
      if (!mounted || _adBlockStopped) return false;
      if (!wasPlaying) await _betterPlayerController.pause();
      unawaited(_loadIntroDbTimings());

      setState(() {
        _currentProviderCode = providerCode;
        _activeSources = Map<String, String>.of(sources);
        _activeSubtitles = List<BetterPlayerSubtitlesSource>.of(selectedSubtitles);
        _activeVideoFormats = Map<String, BetterPlayerVideoFormat?>.of(formats);
        _activeVideoHeaders = Map<String, Map<String, String>>.of(headers);
        _activeVideoSizeTokens = Map<String, String>.of(sizeTokens);
        _activeStreamUrl = linkUrl;
        _activeStreamServerName = providerName.isNotEmpty
            ? providerName
            : _providerDisplayName(providerCode);
        final switchedDuration = _betterPlayerController
            .videoPlayerController?.value.duration?.inSeconds;
        if (switchedDuration != null) duration = switchedDuration;
      });
      _failedStreamUrlsByProvider[providerCode]?.remove(linkUrl);
      _refreshedStreamUrlsByProvider[providerCode]?.remove(linkUrl);
      _exhaustedProviderCodes.remove(providerCode);
      _analyticsProviderSwitchCount++;
      settings.analytics.trackStreamServerChanged(
        mediaType: _analyticsMediaType,
        serverName: _activeStreamServerName!,
        contentId: _analyticsContentId,
        contentTitle: _analyticsContentTitle,
      );
      settings.analytics.trackProviderAttempt(
        mediaType: _analyticsMediaType,
        contentId: _analyticsContentId,
        contentTitle: _analyticsContentTitle,
        provider: _activeStreamServerName!,
        purpose: 'provider_switch',
        success: true,
        durationMs: analyticsStopwatch.elapsedMilliseconds,
        sourceCount: sources.length,
        subtitleCount: _activeSubtitles.length,
      );
      _trackPlaybackEvent(
        'provider_switch_succeeded',
        value: _activeStreamServerName!,
      );
      switched = true;
      if (_hasPlaybackInitialized) unawaited(_savePlaybackCache());
      debugPrint(
        '[PlaybackRecovery][LINK_SELECT] provider=$providerCode '
        'server=$_activeStreamServerName quality=${_streamQualityName(requestedLink)} '
        'format=${_streamFormatName(requestedLink)} '
        'availableLinks=${links.length} headers=${requestedLink.headers?.length ?? 0}',
      );
    } catch (error) {
      _failedStreamUrlsByProvider
          .putIfAbsent(providerCode, () => <String>{})
          .add(linkUrl);
      _invalidateCachedStream(providerCode, linkUrl);
      settings.analytics.trackProviderAttempt(
        mediaType: _analyticsMediaType,
        contentId: _analyticsContentId,
        contentTitle: _analyticsContentTitle,
        provider: providerName,
        purpose: 'provider_switch',
        success: false,
        durationMs: analyticsStopwatch.elapsedMilliseconds,
        sourceCount: sources.length,
        subtitleCount: _activeSubtitles.length,
        error: error.toString(),
      );
      _trackPlaybackEvent(
        'provider_switch_failed',
        value: providerName,
        error: error.toString(),
      );
      debugPrint(
        '[PlaybackRecovery][LINK_SELECT_FAILED] provider=$providerCode '
        'server=$providerName: $error',
      );
      if (!mounted || _adBlockStopped) return false;
      if (replacementStarted && previousDataSource != null) {
        try {
          await _betterPlayerController.setupDataSource(
            previousDataSource,
            initialPosition: position,
          );
          if (!wasPlaying) await _betterPlayerController.pause();
        } catch (restoreError) {
          debugPrint('[PlaybackRecovery] Previous stream restore failed: $restoreError');
        }
      } else if (wasPlaying) {
        try {
          await _betterPlayerController.play();
        } catch (playError) {
          debugPrint('[PlaybackRecovery] Playback resume failed: $playError');
        }
      }
      setState(() => _providerErrors[providerCode] = tr('switch_provider_error'));
    } finally {
      if (mounted) {
        setState(() {
          _isSwitchingProvider = false;
          _loadingProviders.remove(providerCode);
        });
        if (switched) {
          closeMenu();
        } else {
          refreshMenu();
          if (widget.useTvControls) {
            _tvControlsController.show(restorePreviousFocus: true);
          }
        }
      }
    }
    return switched;
  }

  Future<bool> _refreshCurrentProviderSource(Duration? position) async {
    final providerCode = _currentProviderCode;
    final providers = widget.availableProviders ?? const <VideoProvider>[];
    if (!mounted || providerCode == null || providers.isEmpty) return false;

    final failedUrl = _activeStreamUrl?.trim();
    debugPrint(
      '[PlaybackRecovery][AUTOMATIC_FAILOVER_TRIGGER] '
      'provider=$providerCode positionMs=${position?.inMilliseconds ?? -1} '
      'failedUrlPresent=${failedUrl?.isNotEmpty == true}',
    );
    if (failedUrl != null && failedUrl.isNotEmpty) {
      _failedStreamUrlsByProvider
          .putIfAbsent(providerCode, () => <String>{})
          .add(failedUrl);
      _invalidateCachedStream(providerCode, failedUrl);
    }

    final nextLink = _nextProviderStreamAfterFailure(providerCode);
    if (nextLink != null) {
      debugPrint(
        '[PlaybackRecovery][NEXT_LINK] provider=$providerCode '
        'server=${_streamServerName(nextLink)}',
      );
      return _activateProviderStream(
        providerCode,
        nextLink,
        resumeAt: position,
        resumePlayback: true,
        refreshMenu: () {},
        closeMenu: () {},
      );
    }

    final refreshedUrls = _refreshedStreamUrlsByProvider
        .putIfAbsent(providerCode, () => <String>{});
    final shouldRefresh = failedUrl != null &&
        failedUrl.isNotEmpty &&
        refreshedUrls.add(failedUrl);
    if (shouldRefresh) {
      debugPrint('[PlaybackRecovery][REFRESH] provider=$providerCode');
      final refreshed = await _switchToProvider(
        providerCode,
        reload: true,
        resumeAt: position,
        refreshMenu: () {},
        closeMenu: () {},
      );
      if (refreshed) return true;
    }

    _exhaustedProviderCodes.add(providerCode);
    return _switchToNextAvailableProvider(providerCode, position);
  }

  RegularVideoLinks? _nextProviderStreamAfterFailure(String providerCode) {
    final links = _rawVideoLinksByProvider[providerCode] ?? const [];
    final failed = _failedStreamUrlsByProvider[providerCode] ?? const <String>{};
    final currentServer = _activeStreamServerName;
    final candidates = links.where((link) {
      final url = link.url?.trim();
      return url != null &&
          url.isNotEmpty &&
          url != _activeStreamUrl &&
          !failed.contains(url);
    }).toList(growable: false);
    if (candidates.isEmpty) return null;
    for (final candidate in candidates) {
      if (_streamServerName(candidate) != currentServer) return candidate;
    }
    return candidates.first;
  }

  Future<bool> _switchToNextAvailableProvider(
    String failedProviderCode,
    Duration? position,
  ) async {
    final providers = widget.availableProviders ?? const <VideoProvider>[];
    final candidates = providers
        .where((candidate) =>
            candidate.codeName != failedProviderCode &&
            !_exhaustedProviderCodes.contains(candidate.codeName))
        .toList(growable: false);
    // Prefer a provider already resolved by the background scan. This avoids
    // a second network request when a usable alternative is already cached.
    candidates.sort((a, b) {
      final aReady = _rawVideoLinksByProvider[a.codeName]?.isNotEmpty == true;
      final bReady = _rawVideoLinksByProvider[b.codeName]?.isNotEmpty == true;
      if (aReady == bReady) return providers.indexOf(a).compareTo(providers.indexOf(b));
      return aReady ? -1 : 1;
    });

    for (final candidate in candidates) {
      final readyLinks = _rawVideoLinksByProvider[candidate.codeName] ?? const [];
      final failed = _failedStreamUrlsByProvider[candidate.codeName] ?? const <String>{};
      final usable = readyLinks.where((link) {
        final url = link.url?.trim();
        return url != null && url.isNotEmpty && !failed.contains(url);
      }).toList(growable: false);
      if (usable.isNotEmpty) {
        debugPrint(
          '[PlaybackRecovery][AUTOMATIC_FAILOVER] '
          'from=$failedProviderCode to=${candidate.codeName} '
          'server=${_streamServerName(usable.first)} reason=previous_source_failed',
        );
        final switched = await _activateProviderStream(
          candidate.codeName,
          usable.first,
          resumeAt: position,
          resumePlayback: true,
          refreshMenu: () {},
          closeMenu: () {},
        );
        if (switched) return true;
      } else {
        debugPrint(
          '[PlaybackRecovery][AUTOMATIC_FAILOVER] '
          'from=$failedProviderCode to=${candidate.codeName} '
          'reason=resolve_after_previous_source_failed',
        );
        final switched = await _switchToProvider(
          candidate.codeName,
          resumeAt: position,
          refreshMenu: () {},
          closeMenu: () {},
        );
        if (switched) return true;
      }
      _exhaustedProviderCodes.add(candidate.codeName);
    }
    debugPrint('[PlaybackRecovery][EXHAUSTED] after=$failedProviderCode');
    return false;
  }

  String? _preferredProviderResolutionKey(
    String providerCode,
    ProviderVideoSource source,
  ) {
    final links = source.rawVideoLinks;
    if (links.isEmpty) {
      return VideoUtils.preferredVideoSource(
        source.videoSources,
        widget.settings.defaultVideoResolution,
      )?.key;
    }
    final keys = VideoUtils.videoSourceKeys(links);
    final failed = _failedStreamUrlsByProvider[providerCode] ?? const <String>{};
    final available = <String, String>{};
    for (var index = 0; index < links.length && index < keys.length; index++) {
      final url = links[index].url?.trim();
      if (url != null &&
          url.isNotEmpty &&
          !failed.contains(url) &&
          source.videoSources.containsKey(keys[index])) {
        available[keys[index]] = source.videoSources[keys[index]]!;
      }
    }
    return VideoUtils.preferredVideoSource(
      available,
      widget.settings.defaultVideoResolution,
    )?.key;
  }

  /// Switches to [providerCode], or with [reload] resolves the current
  /// provider again for a fresh link. Returns whether the new source is set up.
  Future<bool> _switchToProvider(
    String providerCode, {
    required VoidCallback refreshMenu,
    required VoidCallback closeMenu,
    bool reload = false,
    Duration? resumeAt,
  }) async {
    if (_adBlockStopped ||
        _isSwitchingProvider ||
        (!reload && providerCode == _currentProviderCode)) {
      return false;
    }
    if (!reload) {
      _feedbackSourceSwitches++;
      // A user-initiated retry of an exhausted provider must not reuse its
      // expired cached URLs. Fresh providers keep their already-resolved cache.
      final hadFailedLinks =
          _failedStreamUrlsByProvider[providerCode]?.isNotEmpty == true;
      if (hadFailedLinks || _exhaustedProviderCodes.contains(providerCode)) {
        _loadedProviders.remove(providerCode);
        _providerResults.remove(providerCode);
      }
      _failedStreamUrlsByProvider.remove(providerCode);
      _refreshedStreamUrlsByProvider.remove(providerCode);
      _exhaustedProviderCodes.remove(providerCode);
    }
    final analyticsStopwatch = Stopwatch()..start();
    final providerName = _providerDisplayName(providerCode);
    final analyticsPurpose = reload ? 'source_refresh' : 'provider_switch';
    if (reload) {
      // The cached links are the ones that stopped working.
      _loadedProviders.remove(providerCode);
      _providerResults.remove(providerCode);
    }

    setState(() {
      _isSwitchingProvider = true;
      _loadingProviders.add(providerCode);
      _providerErrors.remove(providerCode);
    });
    refreshMenu();

    final position = resumeAt ??
        _betterPlayerController.videoPlayerController?.value.position ??
        Duration.zero;
    // A refresh replaces a source that failed while the viewer watched it.
    final wasPlaying = reload ||
        _betterPlayerController.videoPlayerController?.value.isPlaying == true;
    final previousDataSource = _betterPlayerController.betterPlayerDataSource;
    var replacementStarted = false;
    var switched = false;
    try {
      await _betterPlayerController.pause();
      var source = _loadedProviders[providerCode];
      if (source == null) {
        final providers = widget.availableProviders ?? const <VideoProvider>[];
        final provider = providers.cast<VideoProvider?>().firstWhere(
          (candidate) => candidate?.codeName == providerCode,
          orElse: () => null,
        );
        if (provider == null) {
          throw StateError('Provider is no longer available: $providerCode');
        }
        final resultFuture = _providerResults[providerCode] ??=
            widget.mediaType == MediaType.movie
                ? ProviderLoader.loadMovieFromProvider(
                    provider: provider,
                    movieId: widget.movieMetadata!.movieId!,
                    scraperApiUrl: _resolveScraperApiUrl(),
                    mediaIdentity: ProviderLoader.movieIdentity(
                      tmdbId: widget.movieMetadata!.movieId!,
                      title: widget.movieMetadata!.movieName ??
                          'Movie ${widget.movieMetadata!.movieId}',
                      year: widget.movieMetadata!.releaseYear,
                      isAnime: widget.movieMetadata!.isAnimeContent,
                    ),
                  )
                : ProviderLoader.loadTVFromProvider(
                    provider: provider,
                    tvId: widget.tvMetadata!.tvId!,
                    seasonNumber: widget.tvMetadata!.seasonNumber!,
                    episodeNumber: widget.tvMetadata!.episodeNumber!,
                    scraperApiUrl: _resolveScraperApiUrl(),
                    mediaIdentity: ProviderLoader.episodeIdentity(
                      tmdbId: widget.tvMetadata!.tvId!,
                      title: widget.tvMetadata!.seriesName ??
                          'Series ${widget.tvMetadata!.tvId}',
                      seasonNumber: widget.tvMetadata!.seasonNumber!,
                      episodeNumber: widget.tvMetadata!.episodeNumber!,
                      episodeTmdbId: widget.tvMetadata!.episodeId,
                      episodeAirDate: widget.tvMetadata!.airDate,
                      isAnime: widget.tvMetadata!.isAnime,
                    ),
                  );
        final result = await resultFuture;
        final failedUrls = _failedStreamUrlsByProvider[providerCode] ?? const <String>{};
        final playbackLinks = (result.videoLinks ?? const <RegularVideoLinks>[])
            .where((link) => !reload || !failedUrls.contains(link.url?.trim()))
            .map((link) => link.copyWith(
                  providerCode: providerCode,
                  server: link.server?.trim().isNotEmpty == true
                      ? link.server
                      : provider.displayName,
                ))
            .toList(growable: false);
        if (!result.success || playbackLinks.isEmpty) {
          // Failed futures are not cached, allowing a later explicit retry.
          _providerResults.remove(providerCode);
          throw Exception(result.errorMessage ?? 'No unfailed links remain for this source.');
        }

        final subtitles = _buildProviderSubtitles(
          result.subtitleLinks ?? const <RegularSubtitleLinks>[],
        );
        source = ProviderVideoSource(
          providerCode: providerCode,
          providerName: provider.displayName,
          videoSources: VideoUtils.reverseVideoQualityMap(
            VideoUtils.convertVideoLinksToMap(playbackLinks),
          ),
          videoFormats: VideoUtils.reverseVideoQualityMap(
            VideoUtils.convertVideoFormatsToMap(playbackLinks),
          ),
          videoHeaders: VideoUtils.reverseVideoQualityMap(
            VideoUtils.convertVideoHeadersToMap(playbackLinks),
          ),
          videoSizeTokens: VideoUtils.reverseVideoQualityMap(
            VideoUtils.convertVideoSizeTokensToMap(playbackLinks),
          ),
          subtitles: subtitles,
          rawVideoLinks: playbackLinks,
        );
        _loadedProviders[providerCode] = source;
        _rawVideoLinksByProvider[providerCode] = List.of(playbackLinks);
        _subtitleLinksByProvider[providerCode] =
            List<RegularSubtitleLinks>.of(result.subtitleLinks ?? const []);
        _mergeAggregateLinks(playbackLinks);
        // Manual/lazy provider resolution must feed the same independent
        // adaptive-quality catalogue as the background scan.
        unawaited(_scanAdaptiveQualityLinks(playbackLinks));
      }

      if (!mounted || _adBlockStopped) return false;
      final nextSource = source;
      final selectedProviderKey =
          _preferredProviderResolutionKey(providerCode, nextSource);
      replacementStarted = true;
      _preRollActive = false;
      _startupPlaybackWatchStartedAt = DateTime.now();
      await _betterPlayerController.setupDataSource(
        _buildDataSource(
          sources: nextSource.videoSources,
          subtitles: nextSource.subtitles,
          videoFormats: nextSource.videoFormats,
          videoHeaders: nextSource.videoHeaders,
          selectedResolution: selectedProviderKey,
        ),
        initialPosition: position,
      );
      if (!mounted || _adBlockStopped) return false;
      _applyPreferredAdaptiveQuality();
      if (!wasPlaying) await _betterPlayerController.pause();
      unawaited(_loadIntroDbTimings());

      if (!mounted) return false;
      setState(() {
        _currentProviderCode = providerCode;
        _activeSources = Map.of(nextSource.videoSources);
        _activeSubtitles = List.of(nextSource.subtitles);
        _activeVideoFormats = Map.of(nextSource.videoFormats);
        _activeVideoHeaders = Map.of(nextSource.videoHeaders);
        _activeVideoSizeTokens = Map.of(nextSource.videoSizeTokens);
        if (selectedProviderKey != null) {
          _activeStreamUrl = nextSource.videoSources[selectedProviderKey];
          _activeStreamServerName = _serverNameForUrl(
            _activeStreamUrl ?? '',
            providerCode: providerCode,
          );
        } else {
          _activeStreamUrl = null;
          _activeStreamServerName = nextSource.providerName;
        }
        final switchedDuration = _betterPlayerController
            .videoPlayerController?.value.duration?.inSeconds;
        if (switchedDuration != null) duration = switchedDuration;
      });
      if (!reload) {
        _analyticsProviderSwitchCount++;
        settings.analytics.trackStreamServerChanged(
          mediaType: _analyticsMediaType,
          serverName: nextSource.providerName,
          contentId: _analyticsContentId,
          contentTitle: _analyticsContentTitle,
        );
      }
      settings.analytics.trackProviderAttempt(
        mediaType: _analyticsMediaType,
        contentId: _analyticsContentId,
        contentTitle: _analyticsContentTitle,
        provider: nextSource.providerName,
        purpose: analyticsPurpose,
        success: true,
        durationMs: analyticsStopwatch.elapsedMilliseconds,
        sourceCount: nextSource.videoSources.length,
        subtitleCount: nextSource.subtitles.length,
      );
      _trackPlaybackEvent(
        '${analyticsPurpose}_succeeded',
        value: nextSource.providerName,
      );
      switched = true;
      if (_hasPlaybackInitialized) unawaited(_savePlaybackCache());
    } catch (error) {
      settings.analytics.trackProviderAttempt(
        mediaType: _analyticsMediaType,
        contentId: _analyticsContentId,
        contentTitle: _analyticsContentTitle,
        provider: providerName,
        purpose: analyticsPurpose,
        success: false,
        durationMs: analyticsStopwatch.elapsedMilliseconds,
        sourceCount: 0,
        subtitleCount: 0,
        error: error.toString(),
      );
      _trackPlaybackEvent(
        '${analyticsPurpose}_failed',
        value: providerName,
        error: error.toString(),
      );
      debugPrint(
        '[Player] Provider ${reload ? 'refresh' : 'switch'} failed for '
        '$providerCode: $error',
      );
      if (!mounted || _adBlockStopped) return false;
      // A refresh has nothing to restore: the previous source is the one
      // that failed.
      if (!reload && replacementStarted && previousDataSource != null) {
        try {
          await _betterPlayerController.setupDataSource(
            previousDataSource,
            initialPosition: position,
          );
          if (!wasPlaying) await _betterPlayerController.pause();
        } catch (restoreError) {
          debugPrint('Unable to restore provider after switch: $restoreError');
        }
      } else if (!reload && wasPlaying) {
        try {
          await _betterPlayerController.play();
        } catch (playError) {
          debugPrint(
              'Unable to resume playback after provider failure: $playError');
        }
      }
      // Provider errors are intentionally kept in debug logs only. Scraper and
      // platform exceptions can contain URLs, native class names, and complete
      // stack traces that should never be rendered in either player UI.
      setState(
        () => _providerErrors[providerCode] = tr('switch_provider_error'),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSwitchingProvider = false;
          _loadingProviders.remove(providerCode);
        });
        if (switched) {
          closeMenu();
        } else {
          // A failed refresh ends on the error view, which takes the focus.
          if (widget.useTvControls && !reload) {
            // A failed switch must return focus to the TV controls; otherwise
            // the remote appears frozen after the error sheet closes.
            _tvControlsController.show(restorePreviousFocus: true);
          }
          refreshMenu();
        }
      }
    }
    return switched;
  }

  @override
  Widget build(BuildContext context) => AdBlockPlaybackGuard(
        stopPlayback: _stopForAdBlocker,
        television: widget.useTvControls,
        child: _buildPlayback(context),
      );

  Widget _buildPlayback(BuildContext context) {
    _handleScreenOrientation(context);
    if (_isPortraitInlineLayout(context)) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _exitPlayer();
        },
        // The page around the video follows the app's mode; the video
        // itself stays black.
        child: PlayerTheme(
          child: Builder(
            builder: (context) => Scaffold(
              backgroundColor: BetterPlayerPanelColors.of(context).page,
              body: _buildPortraitInlineLayout(context),
            ),
          ),
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (widget.useTvControls && _handleTvOverlayBack()) return;
          if (widget.useTvControls && _tvControlsController.handleBack()) {
            return;
          }
          _exitPlayer();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: SizedBox(
                child: BetterPlayer(
                  controller: _betterPlayerController,
                  key: _betterPlayerKey,
                ),
              ),
            ),
            if (_tvMenu case final menu?)
              Positioned.fill(
                child: BetterPlayerTvMenu(
                  title: menu.title,
                  strings: playerControlsStrings(),
                  items: menu.items,
                  onClose: _closeTvMenu,
                  accentColor: widget.colors.first,
                ),
              ),
            if (_tvSubtitleTimingOpen)
              Positioned.fill(
                child: TvSubtitleTimingPanel(
                  controller: _betterPlayerController,
                  onClose: _closeTvSubtitleTiming,
                  accentColor: widget.colors.first,
                ),
              ),
            if (_tvNextEpisode case final nextEpisode?)
              Positioned.fill(
                child: _TvNextEpisodeOverlay(
                  episode: nextEpisode,
                  countdown: _tvNextEpisodeCountdown,
                  countdownTotal: _tvNextEpisodeCountdownTotal,
                  cancelLabel: _tvNextEpisodeAtCredits
                      ? tr('watch_credits')
                      : tr('cancel'),
                  onCancel: _dismissTvNextEpisodePrompt,
                  busy: _startingContent,
                  onPlay: () => _playTvEpisode(nextEpisode),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _handleScreenOrientation(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    final changed = _lastScreenOrientation != orientation;
    _lastScreenOrientation = orientation;

    if (orientation == Orientation.portrait) {
      _landscapeFullscreenRequestPending = false;
      return;
    }
    if (!changed ||
        widget.useTvControls ||
        _betterPlayerController.isFullScreen ||
        _landscapeFullscreenRequestPending) {
      return;
    }

    _landscapeFullscreenRequestPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _landscapeFullscreenRequestPending = false;
      if (MediaQuery.of(context).orientation == Orientation.landscape &&
          !_betterPlayerController.isFullScreen) {
        _betterPlayerController.enterFullScreen();
      }
    });
  }

  MediaIdentity get _playbackCacheIdentity {
    if (widget.mediaType == MediaType.movie) {
      final metadata = widget.movieMetadata!;
      return ProviderLoader.movieIdentity(
        tmdbId: metadata.movieId!,
        title: metadata.movieName ?? 'Movie ${metadata.movieId}',
        year: metadata.releaseYear,
        isAnime: metadata.isAnimeContent,
      );
    }
    final metadata = widget.tvMetadata!;
    return ProviderLoader.episodeIdentity(
      tmdbId: metadata.tvId!,
      title: metadata.seriesName ?? 'Series ${metadata.tvId}',
      seasonNumber: metadata.seasonNumber!,
      episodeNumber: metadata.episodeNumber!,
      episodeTmdbId: metadata.episodeId,
      episodeAirDate: metadata.airDate,
      isAnime: metadata.isAnime,
    );
  }

  void _notifyStreamCatalogChanged() {
    _streamCatalogRevision.value = _streamCatalogRevision.value + 1;
  }

  void _mergeAggregateLinks(List<RegularVideoLinks> incoming) {
    final aggregate = _rawVideoLinksByProvider.putIfAbsent(
      VideoProvider.unifiedSources.codeName,
      () => <RegularVideoLinks>[],
    );
    var changed = false;
    for (final link in incoming) {
      final providerCode = link.providerCode ?? '';
      final headers = (link.headers ?? const <String, String>{}).entries
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final signature = headers.map((entry) => '${entry.key}:${entry.value}').join('|');
      final exists = aggregate.any((current) {
        final currentHeaders =
            (current.headers ?? const <String, String>{}).entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key));
        final currentSignature = currentHeaders
            .map((entry) => '${entry.key}:${entry.value}')
            .join('|');
        return current.providerCode == providerCode &&
            current.url == link.url &&
            current.quality == link.quality &&
            currentSignature == signature;
      });
      if (!exists) {
        aggregate.add(link);
        changed = true;
      }
    }
    if (changed) _notifyStreamCatalogChanged();
  }

  List<BetterPlayerSubtitlesSource> _buildProviderSubtitles(
    List<RegularSubtitleLinks> subtitles,
  ) {
    final preferredLanguage =
        _normaliseSubtitleLanguage(settings.defaultSubtitleLanguage);
    var preferredAssigned = false;
    final sources = <BetterPlayerSubtitlesSource>[];
    for (final subtitle in subtitles) {
      final url = subtitle.url?.trim();
      if (url == null || url.isEmpty) continue;
      final language = _normaliseSubtitleLanguage(subtitle.language);
      final selectedByDefault = preferredLanguage.isNotEmpty &&
          language == preferredLanguage &&
          !preferredAssigned;
      if (selectedByDefault) preferredAssigned = true;
      sources.add(
        BetterPlayerSubtitlesSource(
          type: BetterPlayerSubtitlesSourceType.network,
          urls: <String>[url],
          name: subtitle.language ?? tr('not_available'),
          headers: subtitle.headers,
          selectedByDefault: selectedByDefault,
        ),
      );
    }
    return sources;
  }

  ProviderVideoSource _providerSourceFromResult({
    required VideoProvider provider,
    required ProviderLoadResult result,
  }) {
    final links = result.videoLinks ?? const <RegularVideoLinks>[];
    final subtitles = _buildProviderSubtitles(
      result.subtitleLinks ?? const <RegularSubtitleLinks>[],
    );
    return ProviderVideoSource(
      providerCode: provider.codeName,
      providerName: provider.displayName,
      videoSources: VideoUtils.reverseVideoQualityMap(
        VideoUtils.convertVideoLinksToMap(links),
      ),
      videoFormats: VideoUtils.reverseVideoQualityMap(
        VideoUtils.convertVideoFormatsToMap(links),
      ),
      videoHeaders: VideoUtils.reverseVideoQualityMap(
        VideoUtils.convertVideoHeadersToMap(links),
      ),
      videoSizeTokens: VideoUtils.reverseVideoQualityMap(
        VideoUtils.convertVideoSizeTokensToMap(links),
      ),
      subtitles: subtitles,
      rawVideoLinks: links,
    );
  }

  void _handleProviderScanUpdate(ProviderScanUpdate update) {
    final code = update.provider.codeName;
    final activeUrlBeforeScanUpdate = _activeStreamUrl;
    final activeProviderBeforeScanUpdate = _currentProviderCode;
    if (update.isStarted) {
      _notifyStreamCatalogChanged();
      if (mounted) {
        setState(() {
          _loadingProviders.add(code);
          _providerErrors.remove(code);
        });
      }
      return;
    }

    _loadingProviders.remove(code);
    final result = update.result!;
    final sourceLinks = result.videoLinks ?? const <RegularVideoLinks>[];
    final links = sourceLinks
        .map((link) => link.copyWith(
              providerCode: code,
              server: link.server?.trim().isNotEmpty == true
                  ? link.server
                  : update.provider.displayName,
            ))
        .where((link) => link.url?.trim().isNotEmpty == true)
        .toList(growable: false);
    if (result.success && links.isNotEmpty) {
      final normalized = ProviderLoadResult(
        success: true,
        videoLinks: links,
        subtitleLinks: result.subtitleLinks,
      );
      _rawVideoLinksByProvider[code] = links;
      _subtitleLinksByProvider[code] =
          List<RegularSubtitleLinks>.of(result.subtitleLinks ?? const []);
      _providerResults[code] = Future<ProviderLoaderResult>.value(normalized);
      _loadedProviders[code] = _providerSourceFromResult(
        provider: update.provider,
        result: normalized,
      );
      _mergeAggregateLinks(links);
      unawaited(_scanAdaptiveQualityLinks(links));
      _providerErrors.remove(code);
      _exhaustedProviderCodes.remove(code);
      if (_hasPlaybackInitialized) unawaited(_savePlaybackCache());
    } else {
      _providerErrors[code] = result.errorMessage?.trim().isNotEmpty == true
          ? ProviderLoader.sanitizeDiagnosticError(result.errorMessage)
          : tr('video_source');
      _exhaustedProviderCodes.add(code);
    }
    _notifyStreamCatalogChanged();
    // A provider discovery event only extends the catalogue. It must never
    // call setupDataSource, change _activeStreamUrl, or change _currentProviderCode.
    assert(_activeStreamUrl == activeUrlBeforeScanUpdate);
    assert(_currentProviderCode == activeProviderBeforeScanUpdate);
    debugPrint(
      '[PlaybackScan][CATALOG_ONLY] provider=$code '
      'activeProvider=$_currentProviderCode '
      'activeUrlUnchanged=${_activeStreamUrl == activeUrlBeforeScanUpdate}',
    );
    if (mounted) setState(() {});
  }

  Future<void> _savePlaybackCache() async {
    if (!_hasPlaybackInitialized || _currentProviderCode == null) return;
    if (_cacheWriteInProgress) {
      _cacheWritePending = true;
      return;
    }
    _cacheWriteInProgress = true;
    try {
      do {
        _cacheWritePending = false;
        final providers = <String, CachedProviderStreams>{};
        for (final entry in _rawVideoLinksByProvider.entries) {
          final code = entry.key;
          if (code == VideoProvider.unifiedSources.codeName) continue;
          final links = entry.value.where((link) {
            final url = link.url?.trim();
            return url != null &&
                url.isNotEmpty &&
                !(_failedStreamUrlsByProvider[code]?.contains(url) ?? false);
          }).toList(growable: false);
          if (links.isEmpty) continue;
          providers[code] = CachedProviderStreams(
            providerCode: code,
            providerName: _providerDisplayName(code),
            videoLinks: links,
            subtitleLinks: _subtitleLinksByProvider[code] ??
                const <RegularSubtitleLinks>[],
          );
        }
        final activeUrl = _activeStreamUrl?.trim();
        if (providers.isNotEmpty && activeUrl?.isNotEmpty == true) {
          await _playbackCache.save(
            identity: _playbackCacheIdentity,
            providers: providers,
            lastProviderCode: _currentProviderCode,
            lastUrl: activeUrl,
          );
        }
      } while (_cacheWritePending);
    } catch (error) {
      debugPrint('[PlaybackCache][SAVE_ERROR] ${error.runtimeType}');
    } finally {
      _cacheWriteInProgress = false;
    }
  }

  void _invalidateCachedStream(String providerCode, String url) {
    unawaited(_playbackCache.invalidateUrl(
      identity: _playbackCacheIdentity,
      providerCode: providerCode,
      url: url,
    ));
  }

  bool _isPortraitInlineLayout(BuildContext context) {
    return !widget.useTvControls &&
        MediaQuery.orientationOf(context) == Orientation.portrait &&
        !_betterPlayerController.isFullScreen;
  }

  Widget _buildPortraitInlineLayout(BuildContext context) {
    return PlayerWatchLayout(
      video: BetterPlayer(
        controller: _betterPlayerController,
        key: _betterPlayerKey,
      ),
      slivers: widget.mediaType == MediaType.tvShow
          ? _seriesWatchSlivers()
          : _movieWatchSlivers(),
    );
  }

  /// The watch page's actions, the ones the controls also offer, so they
  /// can be found without bringing the controls up.
  List<WatchAction> get _watchActions {
    final providers = widget.availableProviders ?? const <VideoProvider>[];
    String? providerName;
    for (final provider in providers) {
      if (provider.codeName == _currentProviderCode) {
        providerName = provider.displayName;
      }
    }
    return <WatchAction>[
      if (providers.isNotEmpty)
        WatchAction(
          icon: PhosphorIcons.hardDrives(),
          label: providerName ?? tr('switch_provider'),
          busy: _isSwitchingProvider,
          onTap: _showProviderSwitcher,
        ),
      WatchAction(
        icon: PhosphorIcons.closedCaptioning(),
        label: tr('player_subtitles'),
        onTap: _showSubtitleSwitcher,
      ),
      WatchAction(
        icon: PhosphorIcons.downloadSimple(),
        label: tr('download_action'),
        onTap: () => unawaited(_downloadFromCurrentProvider()),
      ),
      WatchAction(
        icon: PhosphorIcons.arrowSquareOut(),
        label: tr('open_external'),
        onTap: _showExternalPlayerSheet,
      ),
    ];
  }

  List<Widget> _movieWatchSlivers() {
    final metadata = widget.movieMetadata;
    final recommendations =
        metadata?.recommendations ?? const <MovieRecommendation>[];
    final meta = <String>[
      if (metadata?.releaseYear != null) '${metadata!.releaseYear}',
      ...?metadata?.genres.take(3),
    ].join(' · ');
    return <Widget>[
      SliverToBoxAdapter(
        child: WatchHeader(
          title: metadata?.movieName ?? '',
          meta: meta,
          washImageUrl: tmdbImage(
            metadata?.backdropPath ?? metadata?.posterPath,
            'w300',
          ),
          actions: _watchActions,
        ),
      ),
      if (recommendations.isNotEmpty) ...<Widget>[
        SliverToBoxAdapter(
          child: WatchSectionHeader(title: tr('more_like_this')),
        ),
        WatchPosterGrid(
          itemCount: recommendations.length,
          itemBuilder: (context, index) {
            final movie = recommendations[index];
            final facts = _movieFacts(movie);
            return WatchPosterTile(
              title: movie.title,
              posterUrl: tmdbImage(movie.posterPath, 'w342'),
              semanticLabel:
                  facts.isEmpty ? movie.title : '${movie.title}, $facts',
              onTap: () => unawaited(_previewRecommendation(movie)),
            );
          },
        ),
      ],
    ];
  }

  /// A recommendation's backdrop and synopsis first, then Play: a poster
  /// alone is too little to leave this movie for.
  Future<void> _previewRecommendation(MovieRecommendation movie) async {
    final play = await showWatchPreview(
      context,
      title: movie.title,
      meta: _movieFacts(movie),
      overview: movie.overview,
      backdropUrl: tmdbImage(movie.backdropPath ?? movie.posterPath, 'w780'),
    );
    if (play == true && mounted) await _playTvMovie(movie);
  }

  List<Widget> _seriesWatchSlivers() {
    final metadata = widget.tvMetadata;
    // The season on screen, which the season button can change, and the one
    // playing, which Up Next follows whatever is being browsed.
    final episodes = metadata?.seasonEpisodes ?? _contentMenuEpisodes;
    final playingSeason =
        _contentMenuEpisodes.isNotEmpty ? _contentMenuEpisodes : episodes;
    bool isPlaying(EpisodeMetadata episode) =>
        episode.episodeNumber == metadata?.episodeNumber &&
        episode.seasonNumber == metadata?.seasonNumber;
    final playingIndex = playingSeason.indexWhere(isPlaying);
    final playing = playingIndex < 0 ? null : playingSeason[playingIndex];
    final candidate =
        playingIndex < 0 || playingIndex + 1 >= playingSeason.length
            ? null
            : playingSeason[playingIndex + 1];
    final upNext =
        candidate == null || _hasNotAired(candidate) ? null : candidate;

    final seasons = metadata?.allSeasons;
    final browsedSeason = _portraitBrowsedSeasonNumber ??
        episodes.firstOrNull?.seasonNumber ??
        metadata?.seasonNumber;
    String? seasonName;
    for (final season in seasons ?? const <SeasonMetadata>[]) {
      if (season.seasonNumber == browsedSeason) seasonName = season.seasonName;
    }
    final seasonLabel = seasonName ??
        tr('season_number', namedArgs: {'number': '${browsedSeason ?? 1}'});
    final canBrowseSeasons =
        metadata?.tvId != null && (seasons == null || seasons.length > 1);

    final airYear = DateTime.tryParse(
      metadata?.airDate ?? playing?.airDate ?? '',
    )?.year;
    final meta = <String>[
      if (playing?.runtime != null) '${playing!.runtime}m',
      if (airYear != null) '$airYear',
      ...?metadata?.genres.take(2),
    ].join(' · ');

    return <Widget>[
      SliverToBoxAdapter(
        child: WatchHeader(
          kicker: WatchKicker(
            'S${metadata?.seasonNumber ?? '-'} · E${metadata?.episodeNumber ?? '-'}',
          ),
          title: metadata?.seriesName ?? '',
          subtitle: metadata?.episodeName ?? playing?.episodeName,
          meta: meta,
          synopsis: playing?.overview,
          washImageUrl: tmdbImage(
            metadata?.posterPath ?? metadata?.backdropPath,
            'w300',
          ),
          actions: _watchActions,
        ),
      ),
      if (upNext != null)
        SliverToBoxAdapter(
          child: WatchUpNextCard(
            title: 'E${upNext.episodeNumber} · ${upNext.episodeName}',
            meta: upNext.runtime == null ? null : '${upNext.runtime}m',
            imageUrl: tmdbImage(upNext.stillPath, 'w300'),
            onPlay: () => _playUpNext(upNext),
          ),
        ),
      if (episodes.isNotEmpty) ...<Widget>[
        SliverToBoxAdapter(
          child: WatchSectionHeader(
            title: tr('episodes'),
            trailing: canBrowseSeasons
                ? WatchSeasonButton(
                    label: seasonLabel,
                    loading: _portraitSeasonLoading,
                    onTap: _showPortraitSeasonPicker,
                  )
                : WatchCount(seasonLabel),
          ),
        ),
        SliverList.builder(
          itemCount: episodes.length,
          itemBuilder: (context, index) {
            final episode = episodes[index];
            final current = isPlaying(episode);
            final unaired = _hasNotAired(episode);
            return WatchEpisodeTile(
              key: ValueKey<String>(
                '${episode.seasonNumber}-${episode.episodeNumber}',
              ),
              number: episode.episodeNumber,
              title: episode.episodeName,
              meta: _episodeFacts(episode, unaired: unaired),
              synopsis: episode.overview,
              stillUrl: tmdbImage(episode.stillPath, 'w300'),
              current: current,
              upNext: upNext != null &&
                  episode.seasonNumber == upNext.seasonNumber &&
                  episode.episodeNumber == upNext.episodeNumber,
              unaired: unaired,
              progress:
                  current ? WatchLiveProgress(read: _contentProgress) : null,
              onTap: () => _playTvEpisode(episode),
            );
          },
        ),
      ],
    ];
  }

  /// Up Next follows the season playing. If another season is on screen,
  /// the next player gets the playing season's list back, so its own Up
  /// Next and next-episode prompt follow on from here.
  Future<void> _playUpNext(EpisodeMetadata episode) async {
    final metadata = widget.tvMetadata;
    if (metadata != null && _contentMenuEpisodes.isNotEmpty) {
      metadata.seasonEpisodes = List<EpisodeMetadata>.of(_contentMenuEpisodes);
    }
    await _playTvEpisode(episode);
  }

  /// How far into the content playback is, or null during a pre-roll, whose
  /// position isn't the content's.
  double? _contentProgress() {
    if (!mounted || _preRollActive || _awaitingContentAfterPreRoll) {
      return null;
    }
    final value = _betterPlayerController.videoPlayerController?.value;
    final duration = value?.duration;
    if (value == null || duration == null || duration.inMilliseconds <= 0) {
      return null;
    }
    return value.position.inMilliseconds / duration.inMilliseconds;
  }

  Future<void> _showPortraitSeasonPicker() async {
    final metadata = widget.tvMetadata;
    if (!mounted || metadata == null) {
      return;
    }

    if (metadata.allSeasons?.isNotEmpty != true && metadata.tvId != null) {
      setState(() => _portraitSeasonLoading = true);
      try {
        final details = await fetchTVDetails(
          Endpoints.tvDetailsUrl(metadata.tvId!, settings.appLanguage),
          settings.enableProxy,
          _appDependencies.tmdbProxy,
        );
        final loadedSeasons = details.seasons;
        if (loadedSeasons != null && loadedSeasons.isNotEmpty) {
          metadata.allSeasons = loadedSeasons
              .map(SeasonMetadata.fromSeason)
              .where((season) => season.seasonNumber >= 0)
              .toList(growable: false);
        }
      } catch (error) {
        debugPrint(
            '[PlayerContentMenu] portrait season metadata failed: $error');
      } finally {
        if (mounted) setState(() => _portraitSeasonLoading = false);
      }
    }

    final seasons = metadata.allSeasons;
    if (!mounted || seasons == null || seasons.length < 2) return;

    final selectedSeason = await showPlayerSheet<int>(
      context: context,
      builder: (sheetContext) {
        final browsedSeason = _portraitBrowsedSeasonNumber ??
            metadata.seasonEpisodes?.firstOrNull?.seasonNumber ??
            metadata.seasonNumber;
        // As tall as the seasons need, up to most of the screen.
        final size = (.2 + seasons.length * .14).clamp(.35, .9);
        return DraggableScrollableSheet(
          initialChildSize: size,
          minChildSize: .3,
          maxChildSize: .9,
          expand: false,
          builder: (context, scrollController) => PlayerSheetScaffold(
            title: tr('select_season'),
            subtitle: tr(
              'seasons_count',
              namedArgs: {'count': '${seasons.length}'},
            ),
            actions: [
              PlayerSheetAction(
                icon: PhosphorIcons.x(),
                tooltip: tr('close'),
                onPressed: () => Navigator.pop(sheetContext),
              ),
            ],
            child: ListView.separated(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              itemCount: seasons.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final season = seasons[index];
                final selected = season.seasonNumber == browsedSeason;
                return PlayerChoiceCard(
                  title: season.seasonName,
                  subtitle: tr(
                    'episodes_count',
                    namedArgs: {'count': '${season.episodeCount}'},
                  ),
                  description: season.overview,
                  selected: selected,
                  thumbnail: PlayerThumbnail(
                    width: 58,
                    height: 78,
                    child: season.posterPath == null
                        ? Icon(PhosphorIcons.television())
                        : CachedNetworkImage(
                            cacheManager: cacheProp(),
                            imageUrl:
                                'https://image.tmdb.org/t/p/w185${season.posterPath}',
                            fit: BoxFit.cover,
                            placeholder: (_, __) =>
                                const AppCachedImagePlaceholder(),
                            errorWidget: (_, __, ___) =>
                                Icon(PhosphorIcons.television()),
                          ),
                  ),
                  onTap: () => Navigator.pop(sheetContext, season.seasonNumber),
                );
              },
            ),
          ),
        );
      },
    );
    if (!mounted || selectedSeason == null) return;

    final currentBrowsedSeason = _portraitBrowsedSeasonNumber ??
        metadata.seasonEpisodes?.firstOrNull?.seasonNumber ??
        metadata.seasonNumber;
    if (selectedSeason == currentBrowsedSeason) return;

    setState(() => _portraitSeasonLoading = true);
    var loaded = false;
    try {
      loaded = await _episodeSelection.fetchEpisodesForSeason(
        context,
        selectedSeason,
        metadata,
        widget.colors,
      );
    } catch (error) {
      debugPrint('[PlayerContentMenu] portrait season switch failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _portraitSeasonLoading = false;
          if (loaded) _portraitBrowsedSeasonNumber = selectedSeason;
        });
      }
    }
  }

  bool _hasNotAired(EpisodeMetadata episode) {
    final airDate = DateTime.tryParse(episode.airDate ?? '');
    return airDate != null && airDate.isAfter(DateTime.now());
  }

  String? _episodeFacts(EpisodeMetadata episode, {required bool unaired}) {
    final airDate = DateTime.tryParse(episode.airDate ?? '');
    final locale = Localizations.localeOf(context).toString();
    String? date;
    if (airDate != null) {
      try {
        date = DateFormat.yMMMd(locale).format(airDate);
      } catch (_) {
        // A locale without date symbols loaded.
        date = DateFormat.yMMMd().format(airDate);
      }
    }
    if (unaired) {
      return date == null ? null : tr('coming_date', namedArgs: {'date': date});
    }
    final details = <String>[
      if (episode.runtime != null) '${episode.runtime}m',
      if (date != null) date,
    ];
    return details.isEmpty ? null : details.join(' · ');
  }

  String _movieFacts(MovieRecommendation movie) {
    final details = <String>[];
    if (movie.releaseDate?.isNotEmpty == true) {
      details.add(movie.releaseDate!.split('-').first);
    }
    if (movie.voteAverage != null && movie.voteAverage! > 0) {
      details.add('★ ${movie.voteAverage!.toStringAsFixed(1)}');
    }
    return details.join(' · ');
  }

  /// The Next episode control. Fullscreen playback is its own route, so it
  /// is left first, the way the next-episode card does it.
  Future<void> _playNextEpisodeFromControls() async {
    final next = _nextTvEpisode;
    if (next == null || !mounted) return;
    if (!_betterPlayerController.isFullScreen) {
      await _playTvEpisode(next);
      return;
    }
    await _startContent(() async {
      _handleContentSwitch();
      if (!mounted) return;
      _hideContentSwitchLoading();
      _hideNextEpisodeOverlay();
      final navigator = Navigator.of(context);
      _closePlayer();
      await navigator.pushReplacement(
        MaterialPageRoute<void>(
          builder: (context) => AdsterraPlaybackGate.buildLoader(context,
              television: widget.useTvControls,
              content: _seriesAdContent,
              builder: (context) => TVVideoLoader(
                    download: false,
                    metadata: _metadataForTvEpisode(next),
                    adStage: PlaybackAdStage.episodeSwitch,
                  )),
        ),
      );
    });
  }

  StreamFeedbackContext get _streamFeedbackContext {
    final value = _betterPlayerController.videoPlayerController?.value;
    return StreamFeedbackContext(
      mediaType: _analyticsMediaType,
      surface: widget.useTvControls ? 'tv' : 'mobile',
      tmdbId: widget.mediaType == MediaType.movie
          ? widget.movieMetadata?.movieId
          : widget.tvMetadata?.tvId,
      seasonNumber: widget.tvMetadata?.seasonNumber,
      episodeNumber: widget.tvMetadata?.episodeNumber,
      provider: _currentProviderCode ?? 'unknown',
      initialProvider: widget.currentProviderCode ?? 'unknown',
      sourceSwitches: _feedbackSourceSwitches,
      videoHeight: value?.size?.height.round(),
      connectionType: _feedbackConnection.type,
      networkChanges: _feedbackConnection.changes,
    );
  }

  void _sendAutomaticStreamReport() {
    if (!_automaticStreamReport.shouldReport) return;
    unawaited(_automaticStreamReport.send(
      measurement: _feedbackSession.freeze(),
      context: _streamFeedbackContext,
      endReason: _automaticReportEndReason,
      fallbackNetworkBytes: _betterPlayerController.networkBytesTransferred,
      flushNetworkUsage: _flushNetworkUsage,
    ));
  }

  void _exitPlayer() {
    if (_exitingPlayer) return;
    _exitingPlayer = true;
    // Start saving while the context and video position are still available.
    // The save captures them synchronously and can finish after this route pops.
    if (_isVideoInitializedSafely()) {
      _saveRecentProgress();
    }
    final measurement = _feedbackSession.freeze();
    final reportContext = _streamFeedbackContext;
    final metadata = reportContext.parameters;
    // The platform flush is requested before dispose; it never holds Back.
    final networkBytes = _flushNetworkUsage();
    unawaited(_automaticStreamReport.send(
      measurement: measurement,
      context: reportContext,
      endReason: 'user_exit',
      fallbackNetworkBytes: _betterPlayerController.networkBytesTransferred,
      flushNetworkUsage: () => networkBytes,
    ));
    final parameters = networkBytes.then((bytes) => <String, Object>{
          ...metadata,
          ...measurement.parameters(totalBytes: bytes),
        });
    final watched = Duration(milliseconds: _wellnessTracker.watchedMs());
    // Leaving a Kids or Family title opens no popup, owed or not.
    final adFree = ContentAdScope.adFreeAt(context);
    scheduleStreamFeedbackAfterExit(
      context,
      measurement: measurement,
      parameters: parameters,
      onReturned: widget.onTvPlayerExit,
      beforePrompt: widget.useTvControls || adFree
          ? null
          : (context) => AdsterraPlaybackAdsService.instance
              .playerExit(context, watched: watched),
    );
    Navigator.pop(context);
  }

  void _showExternalPlayerSheet() {
    showPlayerSheet<void>(
      context: context,
      builder: (context) => AppResponsiveContent(
        maxWidth: 680,
        padding: EdgeInsets.zero,
        child: ExternalPlay(
          videoSources: _activeSources,
          subtitleSources: _activeSubtitles,
        ),
      ),
    );
  }

  Future<void> _downloadFromCurrentProvider() async {
    if (_activeSources.isEmpty) return;
    if (!mounted || _activeSources.isEmpty) return;
    final providerName = _currentProviderName();
    final downloadApiBaseUrl = _resolveScraperApiUrl();
    final providerCode = _currentProviderCode;
    final downloadProvider = widget.availableProviders
        ?.where((provider) => provider.codeName == providerCode)
        .firstOrNull;
    final rawDownloadLinks = List<RegularVideoLinks>.of(
      _rawVideoLinksByProvider[providerCode] ?? const [],
    );
    final sources = Map<String, String>.of(_activeSources);
    final formats = _activeVideoFormats == null
        ? <String, BetterPlayerVideoFormat?>{}
        : Map<String, BetterPlayerVideoFormat?>.of(_activeVideoFormats!);
    final headers = Map<String, Map<String, String>>.of(_activeVideoHeaders);
    final estimatedSizes = ValueNotifier<Map<String, int?>>({
      for (final entry in _activeVideoSizeTokens.entries)
        if (_streamSizeCacheByToken.containsKey(entry.value))
          entry.key: _streamSizeCacheByToken[entry.value],
    });
    var sizePickerOpen = true;
    unawaited(StreamSizeEstimator.load(
      scraperApiUrl: _resolveScraperApiUrl(),
      tokens: _activeVideoSizeTokens,
      cacheByToken: _streamSizeCacheByToken,
      onEstimate: (token, bytes) {
        if (!sizePickerOpen) return;
        final next = Map<String, int?>.of(estimatedSizes.value);
        for (final entry in _activeVideoSizeTokens.entries) {
          if (entry.value == token) next[entry.key] = bytes;
        }
        estimatedSizes.value = next;
      },
    ));
    final resolution = await DownloadSelectionSheets.showResolution(
      context,
      inPlayer: true,
      resolutions: sources.keys.toList(),
      providerName: providerName,
      estimatedSizesListenable: estimatedSizes,
    );
    sizePickerOpen = false;
    estimatedSizes.dispose();
    if (!mounted || resolution == null) return;

    final url = sources[resolution];
    if (url == null) return;
    final declaredFormat = formats[resolution];
    final format = declaredFormat == BetterPlayerVideoFormat.dash
        ? 'dash'
        : declaredFormat == BetterPlayerVideoFormat.hls
            ? 'hls'
            : url.toLowerCase().contains('.mpd')
                ? 'dash'
                : 'hls';
    final movie = widget.movieMetadata;
    final episode = widget.tvMetadata;
    final isMovie = widget.mediaType == MediaType.movie;
    final season = episode?.seasonNumber ?? 0;
    final episodeNumber = episode?.episodeNumber ?? 0;
    final posterPath = isMovie ? movie?.posterPath : episode?.posterPath;
    final subtitleTrack = _originalSubtitleTrack();

    try {
      final downloadHeaders = headers[resolution] ??
          VideoUtils.inferVideoHeaders(url) ??
          const <String, String>{};
      final audioSelection = await DownloadSelectionSheets.chooseAudio(
        context,
        tracks: OfflineDownloadService.instance.getAudioTracks(
          url: url,
          format: format,
          headers: downloadHeaders,
          maxVideoHeight: _downloadResolutionHeight(resolution),
        ),
        inPlayer: true,
      );
      if (!mounted) return;
      if (audioSelection == null) {
        return;
      }
      await context.read<OfflineDownloadProvider>().enqueue(
            OfflineDownloadRequest(
              id: isMovie
                  ? 'movie_${movie!.movieId}'
                  : 'tv_${episode!.tvId}_s${season}_e$episodeNumber',
              url: url,
              format: format,
              title: isMovie
                  ? movie?.movieName ?? 'Movie'
                  : episode?.seriesName ?? 'TV episode',
              subtitle: isMovie
                  ? 'From $providerName'
                  : 'S${season.toString().padLeft(2, '0')} • '
                      'E${episodeNumber.toString().padLeft(2, '0')} '
                      '${episode?.episodeName ?? ''} • $providerName',
              mediaType: isMovie ? 'movie' : 'episode',
              quality: resolution,
              posterUrl: posterPath == null
                  ? null
                  : '${TMDB_BASE_IMAGE_URL}w500$posterPath',
              maxVideoHeight: _downloadResolutionHeight(resolution),
              headers: downloadHeaders,
              audioTrack: audioSelection.track,
              source: OfflineDownloadSource.forSelection(
                provider: downloadProvider,
                apiBaseUrl: downloadApiBaseUrl,
                links: rawDownloadLinks,
                url: url,
              ),
              contentId: isMovie ? movie?.movieId : episode?.tvId,
              seasonNumber: isMovie ? null : season,
              episodeNumber: isMovie ? null : episodeNumber,
              subtitleTrackUrl: subtitleTrack?.urls!.first,
              subtitleTrackName: subtitleTrack?.name,
              subtitleTrackHeaders: subtitleTrack?.headers ?? const {},
            ),
          );
      settings.analytics.trackDownload(
        action: 'enqueue_from_player',
        mediaType: _analyticsMediaType,
        outcome: 'success',
        provider: providerName,
        quality: resolution,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$resolution download added from $providerName'),
        ),
      );
    } catch (error) {
      settings.analytics.trackDownload(
        action: 'enqueue_from_player',
        mediaType: _analyticsMediaType,
        outcome: isAlreadyDownloaded(error) ? 'already_downloaded' : 'error',
        provider: providerName,
        quality: resolution,
        error: error.toString(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            offlineEnqueueErrorMessage(
              error,
              title:
                  isMovie ? movie?.movieName ?? 'This movie' : 'This episode',
            ),
          ),
        ),
      );
    }
  }

  String _providerDisplayName(String? code) {
    if (code == null || code.trim().isEmpty) return tr('tv_current_provider');
    final loadedName = _loadedProviders[code]?.providerName;
    if (loadedName?.isNotEmpty == true) return loadedName!;
    for (final provider
        in widget.availableProviders ?? const <VideoProvider>[]) {
      if (provider.codeName == code) return provider.displayName;
    }
    return code;
  }

  String _currentProviderName() {
    if (_activeStreamServerName?.trim().isNotEmpty == true) {
      return _activeStreamServerName!;
    }
    return _providerDisplayName(_currentProviderCode);
  }

  int? _downloadResolutionHeight(String resolution) =>
      VideoUtils.videoQualityHeight(resolution);

  BetterPlayerSubtitlesSource? _originalSubtitleTrack() {
    BetterPlayerSubtitlesSource? fallback;
    for (final source in _activeSubtitles) {
      final urls = source.urls;
      if (source.type != BetterPlayerSubtitlesSourceType.network ||
          urls == null ||
          urls.isEmpty ||
          urls.first?.isNotEmpty != true) {
        continue;
      }
      if (source.selectedByDefault == true) return source;
      fallback ??= source;
    }
    return fallback;
  }

  void _showSubtitleSwitcher() {
    final subtitles = List<BetterPlayerSubtitlesSource>.of(
      _betterPlayerController.betterPlayerSubtitlesSourceList,
    );
    final offIndex = subtitles.indexWhere(
      (source) => source.type == BetterPlayerSubtitlesSourceType.none,
    );
    if (offIndex < 0) {
      subtitles.insert(
        0,
        BetterPlayerSubtitlesSource(
          type: BetterPlayerSubtitlesSourceType.none,
        ),
      );
    } else if (offIndex > 0) {
      subtitles.insert(0, subtitles.removeAt(offIndex));
    }

    final options = buildSubtitleOptions(subtitles);

    showPlayerSheet<void>(
      context: context,
      builder: (sheetContext) {
        void then(VoidCallback action) {
          Navigator.pop(sheetContext);
          action();
        }

        return _SubtitleSwitcherSheet(
          controller: _betterPlayerController,
          options: options,
          onClose: () => Navigator.pop(sheetContext),
          onTiming: () => then(_showSubtitleTimingAdjuster),
          onSearchOnline: () => then(() {
            _externalSubtitles.showExternalSubtitlesMenu(
              context: context,
              colors: widget.colors,
              scraperApiUrl: _resolveScraperApiUrl(),
              mediaType: widget.mediaType,
              movieMetadata: widget.movieMetadata,
              tvMetadata: widget.tvMetadata,
              preferredLanguageCode: settings.defaultSubtitleLanguage,
              betterPlayerController: _betterPlayerController,
            );
          }),
          onUpload: () => then(() {
            _localSubtitles.showLocalSubtitlesUpload(
              context: context,
              colors: widget.colors,
              betterPlayerController: _betterPlayerController,
            );
          }),
        );
      },
    );
  }

  void _showSubtitleTimingAdjuster() {
    showPlayerSheet<void>(
      context: context,
      builder: (sheetContext) => PlayerSubtitleTimingSheet(
        controller: _betterPlayerController,
        onClose: () => Navigator.pop(sheetContext),
      ),
    );
  }

  Widget _buildCustomPlayerErrorWidget(BuildContext context) {
    final hasProviders = widget.availableProviders?.isNotEmpty == true;
    return PlayerErrorView(
      title: tr('player_playback_failed'),
      message: tr(hasProviders
          ? 'player_playback_failed_hint'
          : 'player_playback_retry_hint'),
      icon: PhosphorIcons.warningCircle(),
      onClose: _exitPlayer,
      closeLabel: tr('close'),
      actions: [
        if (hasProviders)
          PlayerActionButton(
            label: tr('switch_provider'),
            icon: PhosphorIcons.hardDrives(),
            primary: true,
            autofocus: widget.useTvControls,
            onPressed: widget.useTvControls
                ? _showTvProviderMenu
                : _showProviderSwitcher,
          ),
        PlayerActionButton(
          label: tr('retry'),
          icon: PhosphorIcons.arrowClockwise(),
          primary: !hasProviders,
          autofocus: widget.useTvControls && !hasProviders,
          // Reloads the source (waiting for the network if offline), then
          // resolves the provider again if the link itself has expired.
          onPressed: () => unawaited(_betterPlayerController.retryDataSource()),
        ),
      ],
    );
  }
}

class _TvPlayerMenuData {
  const _TvPlayerMenuData(this.title, this.items);

  final String title;
  final List<BetterPlayerTvMenuItem> items;
}

/// Netflix's next-episode card: bottom end, over the picture rather than
/// dimming it, with the countdown filling the Next episode button. The phone
/// uses it too, with [touch] sizing, lifted by [liftedBy] while the controls'
/// bottom bar is showing.
class _TvNextEpisodeOverlay extends StatelessWidget {
  const _TvNextEpisodeOverlay({
    required this.episode,
    required this.onCancel,
    required this.onPlay,
    required this.cancelLabel,
    this.busy = false,
    this.countdown,
    this.countdownTotal = 10,
    this.touch = false,
    this.liftedBy = 0,
  });

  final bool busy;
  final bool touch;
  final double liftedBy;

  final EpisodeMetadata episode;
  final int? countdown;
  final int countdownTotal;
  final String cancelLabel;
  final VoidCallback onCancel;
  final FutureOr<void> Function() onPlay;

  @override
  Widget build(BuildContext context) {
    final seconds = countdown;
    final elapsed = seconds == null
        ? null
        : ((countdownTotal - seconds + 1) / countdownTotal).clamp(0.0, 1.0);
    // On the TV it follows the app's theme like the player's other panels,
    // shading its corner with the page colour; on the phone it stays white
    // over black, like the controls around it.
    final tv = touch ? null : BetterPlayerTvPanelColors.of(context);
    final shade = tv == null
        ? const Color(0xb3000000)
        : Theme.of(context).scaffoldBackgroundColor.withValues(alpha: .85);
    final foreground = tv?.foreground ?? Colors.white;
    final muted = tv?.muted ?? Colors.white70;
    final placeholder = tv == null
        ? const Color(0xff1b1c1c)
        : Color.alphaBlend(tv.idleFill, shade.withValues(alpha: 1));
    return PlayerTheme(
      onVideo: touch,
      child: Focus(
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.escape ||
                  event.logicalKey == LogicalKeyboardKey.goBack ||
                  event.logicalKey == LogicalKeyboardKey.browserBack)) {
            onCancel();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Only the corner the card sits in is shaded, and the shade takes no
            // taps: the picture and its controls stay usable around the card.
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: AlignmentDirectional.bottomEnd,
                    radius: 1.1,
                    colors: [shade, shade.withValues(alpha: 0)],
                  ),
                ),
              ),
            ),
            AnimatedPadding(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(bottom: liftedBy),
              child: SafeArea(
                minimum: touch
                    ? const EdgeInsets.fromLTRB(20, 16, 20, 20)
                    : const EdgeInsets.fromLTRB(48, 30, 48, 36),
                child: Align(
                  alignment: AlignmentDirectional.bottomEnd,
                  child: SizedBox(
                    width: touch ? 380 : 440,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(5),
                              child: SizedBox(
                                width: touch ? 128 : 160,
                                height: touch ? 72 : 90,
                                child: episode.stillPath == null
                                    ? ColoredBox(
                                        color: placeholder,
                                        child: Icon(
                                          PhosphorIconsRegular.filmStrip,
                                          color: tv?.disabled ?? Colors.white54,
                                          size: 30,
                                        ),
                                      )
                                    : Image.network(
                                        'https://image.tmdb.org/t/p/w300${episode.stillPath}',
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            ColoredBox(color: placeholder),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    tr('next_episode').toUpperCase(),
                                    style: TextStyle(
                                      color: muted,
                                      fontSize: 12,
                                      fontFamily: AppType.semiBold,
                                      letterSpacing: 1.4,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'S${episode.seasonNumber}:E${episode.episodeNumber}  '
                                    '${episode.episodeName}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: foreground,
                                      fontSize: 18,
                                      fontFamily: AppType.semiBold,
                                      height: 1.2,
                                    ),
                                  ),
                                  if (episode.overview?.trim().isNotEmpty ==
                                      true) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      episode.overview!.trim(),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: muted,
                                        fontSize: 13,
                                        fontFamily: AppType.regular,
                                        height: 1.3,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Flexible(
                              child: _TvPromptButton(
                                label: seconds == null
                                    ? tr('next_episode')
                                    : '${tr('next_episode')}  $seconds',
                                icon:
                                    PhosphorIcons.play(PhosphorIconsStyle.fill),
                                progress: elapsed,
                                autofocus: !touch,
                                colors: tv,
                                busy: busy,
                                onPressed: onPlay,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: _TvPromptButton(
                                label: cancelLabel,
                                icon: PhosphorIcons.x(),
                                colors: tv,
                                onPressed: onCancel,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A prompt action: translucent at rest, white under focus, or in the
/// theme's [colors] on the TV. [progress] fills it from the left, for a
/// countdown.
class _TvPromptButton extends StatefulWidget {
  const _TvPromptButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.busy = false,
    this.progress,
    this.autofocus = false,
    this.colors,
  });

  final String label;
  final IconData icon;
  final FutureOr<void> Function() onPressed;
  final bool busy;
  final double? progress;
  final bool autofocus;
  final BetterPlayerTvPanelColors? colors;

  @override
  State<_TvPromptButton> createState() => _TvPromptButtonState();
}

class _TvPromptButtonState extends State<_TvPromptButton> {
  bool _focused = false;
  bool _pressed = false;

  void _press(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) => PlaybackAction(
        onStart: widget.onPressed,
        builder: (context, busy, start) =>
            _buildButton(context, busy || widget.busy, start),
      );

  Widget _buildButton(BuildContext context, bool busy, VoidCallback start) {
    // Focus on a remote, a finger on a phone: either lights it white.
    final lit = _focused || _pressed;
    final colors = widget.colors;
    final foreground = colors == null
        ? (lit ? Colors.black : Colors.white)
        : (lit ? colors.onFocus : colors.foreground);
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onFocusChange: (focused) => setState(() => _focused = focused),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (!busy) start();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: busy ? null : start,
        onTapDown: (_) => _press(true),
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.button),
          child: Stack(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                color: colors == null
                    ? (lit ? const Color(0xf2ffffff) : const Color(0x40ffffff))
                    : (lit ? colors.focusFill : colors.idleFill),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy)
                      SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: foreground),
                      )
                    else
                      Icon(widget.icon, color: foreground, size: 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 15,
                          fontFamily: AppType.semiBold,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.progress case final progress?)
                Positioned.fill(
                  child: IgnorePointer(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: progress),
                      duration: const Duration(seconds: 1),
                      builder: (_, value, __) => FractionallySizedBox(
                        alignment: AlignmentDirectional.centerStart,
                        widthFactor: value,
                        child: ColoredBox(
                          color: foreground.withValues(
                            alpha: lit ? .15 : .2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// IntroDB's intro, recap, credits and preview share one playback action.
class _TvSkipButton extends StatelessWidget {
  const _TvSkipButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => PlayerActionButton(
        label: label,
        icon: PhosphorIcons.skipForward(PhosphorIconsStyle.fill),
        onPressed: onPressed,
      );
}

/// Subtitle languages with timing, online search and file upload tools.
class _SubtitleSwitcherSheet extends StatefulWidget {
  const _SubtitleSwitcherSheet({
    required this.controller,
    required this.options,
    required this.onClose,
    required this.onTiming,
    required this.onSearchOnline,
    required this.onUpload,
  });

  final BetterPlayerController controller;
  final List<SubtitleOption> options;
  final VoidCallback onClose;
  final VoidCallback onTiming;
  final VoidCallback onSearchOnline;
  final VoidCallback onUpload;

  @override
  State<_SubtitleSwitcherSheet> createState() => _SubtitleSwitcherSheetState();
}

class _SubtitleSwitcherSheetState extends State<_SubtitleSwitcherSheet> {
  SubtitleOption? _loadingOption;

  /// Applies [option], letting the controller fall through to its
  /// same-language tracks when it yields nothing: a track can answer with an
  /// error status, or with something the parser cannot read, and either way the
  /// user would be left staring at a video with no captions. A first failure is
  /// not worth a message of its own: the row is marked and, when nothing plays
  /// at all, subtitles go off with the sheet still open. A tap on a row already
  /// known to be dead is the one case worth saying out loud, because there is
  /// nothing left for it to try.
  Future<void> _selectSubtitle(SubtitleOption option) async {
    if (_loadingOption != null) return;
    final controller = widget.controller;
    if (option.sources.every(controller.subtitlesSourceHasFailed)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(tr('subtitle_unavailable_pick_another'))),
      );
      return;
    }

    setState(() => _loadingOption = option);
    BetterPlayerSubtitlesSource? applied;
    try {
      applied = await controller.selectSubtitlesSource(
        option.source,
        fallbacks: option.fallbacks,
      );
    } catch (_) {
      // The walk reports a dead track by leaving it unapplied, so an escaping
      // error needs nothing here beyond not stranding the row on its spinner.
      applied = null;
    }
    if (!mounted) return;
    setState(() => _loadingOption = null);

    final played = applied != null &&
        !controller.subtitlesSourceHasFailed(applied) &&
        applied.type != BetterPlayerSubtitlesSourceType.none;
    if (played || option.isOff) {
      widget.onClose();
      return;
    }
    // Nothing for this language plays. The controller has turned subtitles off
    // rather than leave an empty caption track on screen, and the sheet stays
    // open on the marked row so the user can pick something that works.
  }

  Widget _subtitleRow(SubtitleOption option) {
    final selected = widget.controller.betterPlayerSubtitlesSource;
    final isOff = option.isOff;
    final isSelected = isOff
        ? selected == null ||
            selected.type == BetterPlayerSubtitlesSourceType.none
        : identical(option.source, selected);
    final isLoading = identical(option, _loadingOption);
    // Only a row with nothing left to try is marked: one whose own track died
    // but whose fallbacks are untouched can still play.
    final hasFailed =
        option.sources.every(widget.controller.subtitlesSourceHasFailed);
    final rawName = option.name?.trim();
    final label = isOff
        ? tr('player_off')
        : rawName?.isNotEmpty == true
            ? languageDisplayName(rawName)
            : widget.controller.translations.generalDefault;
    return PlayerChoiceCard(
      title: option.number == null ? label : '$label #${option.number}',
      subtitle: isOff || option.provider.isEmpty ? null : option.provider,
      selected: isSelected,
      trailing: isLoading
          ? Semantics(
              liveRegion: true,
              label: tr('loading_subtitles'),
              child: const SizedBox.square(
                key: Key('subtitle_selection_progress'),
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : hasFailed
              ? Semantics(
                  liveRegion: true,
                  label: tr('subtitle_unavailable_pick_another'),
                  child: Icon(
                    PhosphorIcons.xCircle(PhosphorIconsStyle.fill),
                    key: const Key('subtitle_selection_failed'),
                    size: 20,
                    color: Theme.of(context).colorScheme.error,
                  ),
                )
              : isSelected
                  ? null
                  : const SizedBox.shrink(),
      onTap: _loadingOption == null ? () => _selectSubtitle(option) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final subtitles = [
      for (final option in widget.options) _subtitleRow(option)
    ];
    return DraggableScrollableSheet(
      initialChildSize: .82,
      minChildSize: .5,
      maxChildSize: .95,
      expand: false,
      snap: true,
      builder: (context, scrollController) => PlayerSheetScaffold(
        title: tr('player_subtitles'),
        subtitle: tr('choose_subtitle_language'),
        actions: [
          PlayerSheetAction(
            icon: PhosphorIcons.x(),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: widget.onClose,
          ),
        ],
        footer: _SubtitleTools(
          onTiming: widget.onTiming,
          onSearchOnline: widget.onSearchOnline,
          onUpload: widget.onUpload,
        ),
        child: ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          children: subtitles,
        ),
      ),
    );
  }
}

/// The subtitle tools under the list: timing, searching online, a file.
class _SubtitleTools extends StatelessWidget {
  const _SubtitleTools({
    required this.onTiming,
    required this.onSearchOnline,
    required this.onUpload,
  });

  final VoidCallback onTiming;
  final VoidCallback onSearchOnline;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    Widget tool(IconData icon, String label, VoidCallback onPressed) =>
        OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 18),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            textStyle: const TextStyle(fontFamily: 'FigtreeSB', fontSize: 14),
          ),
        );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: BetterPlayerPanelColors.of(context).hairline),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              tool(PhosphorIcons.timer(), tr('subtitle_timing'), onTiming),
              const SizedBox(width: 8),
              tool(
                PhosphorIcons.magnifyingGlass(),
                tr('external_subtitles'),
                onSearchOnline,
              ),
              const SizedBox(width: 8),
              tool(
                PhosphorIcons.fileArrowUp(),
                tr('upload_subtitles'),
                onUpload,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
