# PHASE 20 — Source pipeline regression audit and FlixQuest movie-player parity

## Scope and comparison baseline

- Target for preservation: the latest supplied CINESTREAM-PRO-N snapshot (Phase 19).
- Working-behaviour reference: the supplied CINESTREAM-PRO-N Phase 17 snapshot.
- Visual/player reference: the supplied `flixquest-main` project.
- Only the `phases/` directory in the latest Phase 19 target was used as the active project policy/history. The Phase 17 `phases/` directory was not used to authorize edits.

This phase is an audit-only continuation. No provider engine, extractor, resolver, loader, adapter, dependency, playback mapping, subtitle, or player-layout source file was changed.

## 1. Phase 17 versus latest Phase 19: source-path findings

The following code and test areas are byte-for-byte identical between the two CINESTREAM snapshots:

- All 29 files under `lib/video_providers/`.
- All files under `lib/screens/movie/` and `lib/screens/tv/`.
- `lib/functions/video_utils.dart`.
- All 11 files under `test/video_providers/` and `test/video_utils_test.dart`.
- `pubspec.yaml` and `pubspec.lock`.

The only common source-code file with a content difference is `lib/screens/common/player.dart`. Its Phase 18 additions are limited to player-facing quality access:

- Restoring the native HD action for mobile series/anime only.
- Exposing the existing provider switch action in the TV controls menu when needed.
- Adding a Quality entry to mobile overflow and TV menus.
- Adding `_showTvQualityMenu()` to present/select entries already in the quality catalogue.

The diff does not modify provider registration, manifest loading, source applicability, content identity, engine execution, extraction/parsing, unified-to-legacy conversion, request-header mapping, HLS/DASH metadata mapping, or the initial provider loading code. Phase 19 removes only unsupported gesture constructor arguments from that same player file.

### Conclusion

There is no code-level evidence that Phase 18/19 changed the source extraction pipeline compared with the supplied Phase 17 snapshot. Because the user reports different runtime behaviour, it would be unsafe to rewrite extractors or alter source identities without a failing-provider trace. The source pipeline was deliberately left untouched.

## 2. Existing runtime diagnostics for the next failure trace

The current project already emits these diagnostic records:

- `[PlaybackSources][DISCOVERY]`: number and names of installed runnable sources.
- `[UnifiedSources][SEARCH]`: repository/catalog/installed counts, attempts, successful source count, playable stream count, converted player-link count, subtitle count and overall success.
- `[UnifiedSources][ATTEMPT]`: individual source/engine result, stream count, elapsed time and sanitized error.
- `[MovieVideoLoader] Request` and `[MovieVideoLoader] Response`: direct provider request/result, links, subtitles and sanitized error.

Interpretation:

- `installedEnabled=0` or `attempts=0`: discovery, installation, engine registration or source applicability stage.
- `attempts>0` with `successfulSources=0` or `playableStreams=0`: source identity, remote extraction or returned-stream validation stage.
- `playableStreams>0` with `playerLinks=0`: unified-result conversion/adapter stage.
- `playerLinks>0` but playback fails: the failure is after extraction; inspect selected URL reachability, required headers, HLS/DASH/container support and the player error.

A runtime trace from one failing source is required to distinguish these cases. The project does not log full stream URLs or header values in these summary records.

## 3. FlixQuest app-level player comparison

The following FlixQuest app files are byte-for-byte identical to the latest CineStream files:

- `lib/screens/common/player/player_watch_page.dart`
- `lib/screens/common/player/player_sheet_ui.dart`
- `lib/screens/common/player/player_strings.dart`
- `lib/screens/common/player/player_feedback_ui.dart`

The main `player.dart` presentation methods `_buildPlayback`, `_handleScreenOrientation`, `_isPortraitInlineLayout`, `_buildPortraitInlineLayout`, `build`, and `_buildCustomPlayerErrorWidget` are also identical between the supplied FlixQuest app and CineStream versions.

CineStream intentionally differs in several supporting player modules; those differences preserve project-specific behaviour and must not be overwritten with FlixQuest files:

- `player_external_subtitles.dart`: Arabic subtitle preference, subtitle playback cache/store and source metadata.
- `player_episode_selection.dart`: anime identity is carried when launching another episode.
- `player_background_save.dart`: Firebase-disabled/local-runtime guard.
- `player_movie_recommendations.dart`: original-language metadata passed into recommendation navigation.

### Movie control selection

CineStream currently selects the default FlixQuest Material controls for movies by leaving `customControlsBuilder` unset and `playerTheme` null for `MediaType.movie`, including the wide-screen/TV movie case. The custom TV controls remain reserved for series/anime as intended by Phase 17. The app-level watch-page and layout methods are already identical to FlixQuest; no parallel replacement UI was created in this phase.

## 4. Missing dependency required for an exact controls transplant

The uploaded `flixquest-main` archive does not contain the sibling package referenced by its `pubspec.yaml`:

`better_player_plus: path: ../flixquest-betterplayer`

That package supplies the actual BetterPlayer control implementation. CINESTREAM instead points to the Git `main` branch of `flixquest-betterplayer`. Phase 19 documented an API mismatch between FlixQuest's local sibling package and the Git dependency (the local version accepted `fastHoldSpeed`/`slowHoldSpeed`; the Git constructor did not).

Therefore the app archive alone is insufficient to transplant the complete, exact BetterPlayer visual implementation or verify that the Git dependency renders precisely the same control tree as the FlixQuest local package. The local `flixquest-betterplayer` source tree is required for a literal package-level parity port. No unsupported gesture parameters or speculative dependency changes were reintroduced.

## 5. Preservation rules applied from the latest target's phase history

The audit preserves the latest target's documented constraints, including:

- Stable source identity and media-type-specific routing from Phase 8 and provider classification from Phase 11.
- The existing direct/fallback source scheduling and cancellation rules from Phase 10.
- All returned qualities and duplicate-quality streams across different servers from Phase 12.
- Background scans may extend the quality catalog but must not replace the active stream from Phase 13.
- SubSource Arabic priority and subtitle state/cache behaviour from Phases 14–15.
- The Phase 17 movie Material controls and series/anime TV controls split.
- Phase 18 quality-catalog entry points, without replacing the extraction or resolver path.
- Phase 19 compatibility with the actual Git BetterPlayer constructor; unsupported gesture arguments remain removed.

No previous phase report was edited or removed.

## 6. Validation and remaining evidence

- File hashes and targeted source diffs were compared between Phase 17 and Phase 19.
- FlixQuest app-level presentation files and selected layout methods were compared directly.
- The archive's `pubspec.yaml` path dependency was checked; the referenced sibling package is not present in the uploaded archive.
- Flutter and Dart SDK executables are not available in this editing environment; no `flutter analyze`, tests, APK build, or live-source playback test is claimed.

### Required inputs to complete the two requested fixes safely

1. The exact `flixquest-betterplayer` sibling package used by the supplied FlixQuest project, as a ZIP or repository archive.
2. A runtime log from one source that fails, including the relevant `[PlaybackSources]`, `[UnifiedSources]`, and `[MovieVideoLoader]` records (or the corresponding TV loader records for series/anime).

Until those are available, changing source engines or replacing player controls would be speculative and could violate the documented Phase 8–19 decisions.
