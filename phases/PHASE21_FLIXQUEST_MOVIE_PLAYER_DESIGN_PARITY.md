# PHASE 21 — FlixQuest movie-player design parity without source-pipeline replacement

## Scope and authoritative inputs

- **Edit target:** the latest supplied CINESTREAM-PRO-N snapshot carried forward in the Phase 20 archive (based on Phase 19).
- **Visual reference:** the re-uploaded `flixquest-main.zip` supplied by the user.
- **Source-behaviour reference:** the supplied Phase 17 CINESTREAM-PRO-N archive.
- **Policy source:** only the `phases/` directory from the latest target snapshot was used to decide what could and could not change. The Phase 17 archive was used as a behavioural comparison only; its `phases/` directory did not authorize edits.

This phase focuses on movie-player presentation parity. It does not replace the CineStream extraction, provider, cache, quality, subtitle-source, or playback-selection architecture.

## 1. Full app-level player design comparison

The supplied FlixQuest archive was re-extracted and inspected directly. The following shared player modules are byte-for-byte identical between FlixQuest and the latest CineStream target:

- `lib/screens/common/player/player_watch_page.dart`
- `lib/screens/common/player/player_sheet_ui.dart`
- `lib/screens/common/player/player_strings.dart`
- `lib/screens/common/player/player_feedback_ui.dart`
- `lib/screens/common/player/player_data_management.dart`
- `lib/screens/common/player/player_completion_detector.dart`
- `lib/screens/common/player/player_next_episode_policy.dart`

The following top-level presentation methods in `lib/screens/common/player.dart` were also compared by method body and are byte-for-byte identical:

- `_buildPlayback`
- `_handleScreenOrientation`
- `_isPortraitInlineLayout`
- `_buildPortraitInlineLayout`
- `build`
- `_buildCustomPlayerErrorWidget`

Therefore, replacing or rebuilding those layout files would not improve visual parity; it would only introduce unnecessary regression risk.

## 2. Movie control configuration and focused restoration

The current CineStream movie path already selects the FlixQuest Material control theme for movies, including the wide-screen movie path as specified by Phase 17. It keeps the same playback surface, progress bar, labelled control row, icons, spacing configuration, skip intervals, and hide timing as the FlixQuest Material configuration.

One actionable difference was found in the mobile movie Audio & Subtitles action:

- FlixQuest calls its player subtitle switcher when the Material action is tapped.
- CineStream had set `onSubtitlesTap` to `null` for movies, allowing the package's default selector to take over instead of CineStream's subtitle sheet.

This phase restores the FlixQuest callback routing for mobile playback:

```dart
onSubtitlesTap: widget.useTvControls ? null : _showSubtitleSwitcher,
```

The existing CineStream `_showSubtitleSwitcher` remains in place. It includes the project's preferred-language handling, external subtitle search, upload and timing actions. The `preferredLanguageCode` passed to external subtitle search is retained; it is not replaced with FlixQuest's older implementation.

## 3. Intentional Phase 17/18 differences preserved

The following are deliberate project decisions recorded in the latest target's phase history. They are not treated as accidental design drift and were not reverted:

- Movies retain the FlixQuest Material control row, including when the app is in the wide-screen/TV movie path.
- Series and anime retain CineStream's existing dedicated TV controls.
- The duplicate native BetterPlayer HD action remains hidden for movies; the cross-provider quality catalogue remains separately accessible from the overflow menu as required by Phases 17–18.
- The provider-switch action and the cross-provider quality menu remain available; they are not moved into or used to redesign FlixQuest's labelled movie control row.
- No unsupported `fastHoldSpeed` or `slowHoldSpeed` constructor arguments are reintroduced. Phase 19's compatibility correction remains in force.
- CineStream-specific subtitle source priority, Arabic defaults, subtitle cache/state, provider identity, source selection, and playback recovery remain intact.

## 4. Source extraction and playback-data preservation

A fresh full `lib/` file comparison was made between the supplied Phase 17 snapshot and the Phase 20 target before this phase's focused callback correction:

- 517 Dart source files existed in each snapshot.
- The only file with a content difference was `lib/screens/common/player.dart`.
- All 29 files under `lib/video_providers/` were identical.
- All files under `lib/screens/movie/` and `lib/screens/tv/` were identical.
- All files under `lib/functions/` were identical.
- All 11 files under `test/video_providers/` were identical.

This phase changes only the movie subtitle-button callback in `player.dart`; it does not change source registration, manifest handling, engine execution, extraction/parsing, provider applicability, loaders, Unified-to-Legacy conversion, URL/header/format mapping, scan scheduling, quality retention, cache restoration, or failover.

The user's reported runtime failures for individual sources are not marked as fixed by this visual parity change. The project already contains `[PlaybackSources][DISCOVERY]`, `[UnifiedSources][SEARCH]`, `[UnifiedSources][ATTEMPT]`, and loader diagnostics. A failing-source runtime trace is still needed to distinguish discovery, extraction, adapter, and post-extraction playback failures without changing working provider code speculatively.

## 5. Files changed in Phase 21

- `lib/screens/common/player.dart` — restored FlixQuest's mobile Material Audio & Subtitles callback routing while retaining CineStream's enhanced subtitle sheet.
- `phases/PHASE21_FLIXQUEST_MOVIE_PLAYER_DESIGN_PARITY.md` — this report.
- `README_CHANGED_FILES.txt` — updated phase summary.

No extractor, provider engine, loader, quality catalog, cache, subtitle service, data adapter, dependency manifest, TV layout, or previous phase report was modified.

## 6. Verification and limitations

- Re-extracted and inspected the re-uploaded FlixQuest archive.
- Re-compared the shared player UI modules and selected presentation method bodies.
- Re-compared the Phase 17 and latest target source trees and provider-related test files.
- Verified that the restored callback is the same FlixQuest Material callback routing while preserving CineStream's `preferredLanguageCode` argument in its subtitle sheet implementation.
- Confirmed that unsupported BetterPlayer gesture parameters remain absent.
- Flutter and Dart SDK executables are not available in this editing environment. `dart format`, `flutter analyze`, `flutter test`, APK assembly, and live playback were not executed. No successful build or live-source playback is claimed.

## Phase policy

Phase 21 is a separate, additive report. Reports from Phases 1–20 remain unchanged. Future edits must continue to follow the latest target's documented preservation rules.
