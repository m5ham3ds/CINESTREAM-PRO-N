# PHASE 25 — FlixQuest handheld action row and three-item More parity

## Scope and reviewed baseline

- Target: latest available CINESTREAM-PRO-N archive, Phase 24.
- Visual reference: `1562630.jpg` (FlixQuest handheld action row) and `1562631.jpg` (FlixQuest More panel).
- Target screenshots: `1565283.jpg` and `1565284.jpg`.
- Reviewed before editing: all target phase reports 11–24, especially Phases 17–24; FlixQuest `lib/screens/common/player.dart`; and the current BetterPlayer Material controls/configuration implementation.

## Confirmed differences before the change

1. CineStream hid the standalone handheld HD action for movies, while FlixQuest shows the quality action on handheld. CineStream therefore displayed five labelled actions rather than the six-item row in the reference screenshot.
2. CineStream added two handheld More entries: its global `Quality` action and `Open in external player`. These expanded the three standard More entries.
3. The BetterPlayer package API currently used by CineStream has no `onQualitiesTap` callback. The native quality control would show active-source tracks and would bypass CineStream's cross-provider quality catalog if used directly.
4. The external-player flow already exists as a portrait watch-page `WatchAction`, so it can be removed from the player More panel without deleting that page-level entry point.

## Changes

Only `lib/screens/common/player.dart` was changed:

- The handheld action row now follows FlixQuest's order using BetterPlayer's existing quick-action renderer:
  1. Speed
  2. Lock
  3. Switch Provider (when providers are available)
  4. More Like This for movies, or Episodes for episodic content
  5. Audio & Subtitles
  6. HD / Quality
- The app-specific callbacks still call CineStream's existing provider switcher, recommendations/episode selector, subtitle bridge, and unified all-provider quality catalog.
- Native duplicate episode/recommendation/subtitle/quality actions are disabled for handheld because those actions are now represented in the ordered `quickActions` list. The TV surface retains its existing native episode/recommendation and TV menu configuration.
- Handheld `overflowMenuCustomItems` is empty. With the existing native speed, crop/fit, and download capabilities enabled, the wide-player More panel contains exactly three options: Playback speed, Crop & fit, Download.
- TV retains its custom quality, subtitle timing, and subtitle upload menu entries.
- `Open in external player` is no longer in the player More panel, but remains accessible from the existing portrait watch-page action list.
- No BetterPlayer library source, player widget, drawing/layout method, icon artwork, animation, spacing, typography, or color was changed.

## Preserved CineStream behavior

- Switch Provider still calls `_showProviderSwitcher` on handheld and `_showTvProviderMenu` on TV.
- The handheld HD action calls `_showQualitySwitcher`, retaining the global provider/source/quality catalog, adaptive manifest variants, source headers and identities, and existing source activation/recovery path.
- Audio & Subtitles calls `_showSubtitleSwitcher`, retaining Arabic preference, SubSource priority, external/local subtitle discovery, uploads, and timing controls.
- Movie recommendations and episode selection use their existing callbacks.
- Download remains `_downloadFromCurrentProvider` and is the third default More entry.
- Provider engines, movie/TV loaders, source extraction, playback cache, failover, and all earlier phase reports are unchanged.
- Anime remains on the episodic (`tvShow`) path.

## Validation

- Static inspection confirms the six handheld movie actions are assembled in the FlixQuest order and rendered by the library's existing action-row component.
- Static inspection confirms there are no handheld custom More entries and only Playback speed, Crop & fit, and Download remain enabled in the wide-player More panel.
- Static inspection confirms the HD action routes to `_showQualitySwitcher`, not the active-source-only native quality selector.
- TV-specific custom menu items remain unchanged.
- SHA-256 comparisons confirm provider engines, movie/TV loaders, quality catalog/scanner, source models, and subtitle services match the Phase 24 baseline.
- ZIP CRC and top-level directory structure are verified.

Flutter/Dart SDK is not installed in this environment; `dart format`, `flutter analyze`, automated tests, and Release APK build could not be run. Icon-only layout and sheet appearance still need on-device confirmation in the same wide/landscape mode as the reference screenshots.
