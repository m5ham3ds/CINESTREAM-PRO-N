# PHASE 24 — FlixQuest player defaults and control-surface parity

## Scope and sources

- **Target project:** the complete CINESTREAM-PRO-N Phase 23 project supplied in the current conversation.
- **Reference:** the uploaded `flixquest-main.zip` source tree.
- **Constraint source:** the latest target project's `phases/` directory, especially Phases 15, 17–23.
- This phase aligns the playback control surface and player defaults. It does not replace `PlayerOne`, the source bridge, movie/episode loaders, provider engines, or playback data models.

## Findings before the change

A direct comparison of `PlayerOne` configuration and the settings provider showed that the core playback defaults were already aligned with FlixQuest:

- autoplay enabled;
- `BoxFit.contain`;
- fullscreen orientation detection enabled on the handheld surface;
- `defaultViewMode` controls initial fullscreen state (default `true` in both projects);
- 10-second seek steps;
- 120-second maximum buffer default;
- 56-pixel control bar;
- 300 ms handheld control auto-hide and 4-second TV control auto-hide;
- controls initially hidden on handheld and shown on TV;
- white control/loading icons, black player background, white/24 progress background, white/38 buffered progress, and the configured app accent for played progress;
- subtitle defaults of white foreground, black-45% background, 17 px, regular style;
- ambient glow disabled by default;
- next-episode control disabled by default;
- the same control gestures and swipe sensitivity values (volume 0.5, brightness 0.5, seek 1.0; gestures disabled on TV).

## Changes made in this phase

### 1. Use the FlixQuest control surface selection for all media types

The prior CineStream condition selected `BetterPlayerTvControls` only when `useTvControls` was true **and** the media was not a movie. FlixQuest selects its TV control surface whenever `useTvControls` is true.

The condition now matches FlixQuest:

- handheld: standard BetterPlayer Material controls for movies and episodic content;
- TV: `BetterPlayerTvControls` for movies, series, and anime/episodes.

The TV control implementation and its artwork were not edited; only the condition selecting the existing control implementation was aligned. Movie/episode actions and CineStream data callbacks remain separate from the visual surface selection.

This is an explicit alignment with the user's current request and supersedes the movie-only TV-surface exception documented in Phase 17. It does not change the fact that anime follows the episodic (`tvShow`) loader and episode flow.

### 2. Match the FlixQuest subtitle action visibility rule

`showSubtitlesButton` now follows the reference condition `!widget.useTvControls` for every media type. On TV, subtitle selection remains inside the TV control menu and CineStream continues to provide its subtitle timing/upload entries there. On handheld, the Audio & Subtitles action still opens CineStream's subtitle sheet, preserving Arabic SubSource priority, external subtitle search, local subtitle upload, and timing controls.

## CineStream-specific behavior intentionally retained

These are data/feature integrations, not changes to the visual defaults, and remain in place:

- `PlayerOne` and `BetterPlayerController` remain the shared playback engine.
- Movie and episodic metadata continue to populate the existing title/subtitle header fields.
- `Switch Provider` continues to call CineStream's provider switchers.
- The global multi-provider quality catalog remains a custom More/Overflow entry; it is not replaced with the active-source-only native quality selector.
- The standalone HD action remains hidden for movies so the movie Material action row retains the five labelled FlixQuest actions and does not gain a duplicate sixth HD action. The global Quality item stays in More/Overflow.
- Subtitle source selection continues through CineStream's subtitle bridge, including Arabic preference and SubSource priority.
- Provider scan sessions, cached results, source identity, headers, formats, HLS/DASH manifest enrichment, playback cache, active-position restoration, source recovery, and failover are unchanged.
- Series and anime continue to use the same episodic data path and metadata handling.

## Defaults deliberately different from FlixQuest

- CineStream's default subtitle language remains Arabic (`ar`), not FlixQuest's English (`en`). This is a deliberate project requirement documented in the Arabic subtitle/SubSource phases; changing it would alter source ranking and automatic subtitle selection.
- The stored long-press speed preferences remain at FlixQuest's values (fast 2.0x, slow 0.5x), but their Settings UI controls and `BetterPlayerGestureConfiguration` wiring remain disabled. Phase 19 records that the Git dependency used by CineStream does not expose `fastHoldSpeed` / `slowHoldSpeed`, and passing those names caused the reported compile failure. They are not reintroduced in this phase to avoid repeating that build break or exposing settings which do not work.
- Movie quality remains represented by CineStream's all-provider Quality catalog, not by a duplicate standalone HD action. This is required to preserve the Phase 17 five-action movie row and multi-provider selection.

## Files changed

- `lib/screens/common/player.dart`
- `PHASE24_FLIXQUEST_PLAYER_DEFAULTS_PARITY.md` (project root copy)
- `phases/PHASE24_FLIXQUEST_PLAYER_DEFAULTS_PARITY.md` (phase archive copy)

No provider extraction, movie/TV loader, data bridge, model, dependency declaration, or existing phase report was changed.

## Validation

- Static comparison confirms the TV theme and custom-control builder now use the same `useTvControls` condition as FlixQuest.
- Static comparison confirms subtitle-button visibility is now `!widget.useTvControls`, matching FlixQuest.
- Core playback configuration values and user settings defaults were compared against FlixQuest; deliberate CineStream differences are documented above.
- Phase 17–23 reports remain unchanged; this Phase 24 report is added independently.
- Provider engines, movie/TV loaders, and source bridge files remain byte-for-byte identical to the Phase 23 base.
- The generated ZIP is checked for CRC/integrity and contains one top-level `CINESTREAM-PRO-N/` directory.

**Build limitation:** Flutter/Dart SDK is not available in this editing environment. `dart format`, `flutter analyze`, Flutter tests, and `assembleProdRelease` could not be run. This phase does not claim a successful APK build; GitHub Actions remains the build verification step.
