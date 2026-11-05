# PHASE 23 — Restore FlixQuest movie action row without the duplicate HD action

## User-visible regression confirmed from screenshots

The comparison screenshots show the intended FlixQuest movie controls with five labelled actions:

- Speed (1x)
- Lock
- Switch Provider
- More Like This
- Subtitles

The CineStream screenshot showed the same actions as icons only, plus a separate HD action in the bottom row. The More sheet already exposed a Quality item.

## Root cause

Phase 17 explicitly requires hiding the standalone HD button for movies. The multi-provider Quality catalogue is exposed separately from the action row through the More/Overflow menu.

Phase 22 incorrectly changed `showQualitiesButton` to `!widget.useTvControls`, which reintroduced the HD control into the mobile Material movie action row. The BetterPlayer Material controls decide whether to display action labels based on whether all configured actions fit. The extra HD action increased the required width and caused the row to fall back to icon-only presentation. This is why the movie player no longer matched the five-labelled-action FlixQuest screenshot.

## Fix

In `lib/screens/common/player.dart`, `showQualitiesButton` now evaluates to true only when the content is not a movie and the player is not using TV controls:

```dart
showQualitiesButton:
    !widget.useTvControls && widget.mediaType != MediaType.movie,
```

This restores the intended five-action movie row without changing the BetterPlayer control widgets, their layout, typography, spacing, icons, colors, sheet presentation, or responsive rules.

## Preserved behavior

- CineStream's multi-provider Quality catalogue remains accessible from the existing More/Overflow entry (`overflowMenuCustomItems`).
- The movie source selection, unified provider bridge, source headers, adaptive HLS/DASH scan, playback cache, failover, subtitles, and SubSource Arabic priority are unchanged.
- The original FlixQuest action order and labels remain controlled by the existing BetterPlayer Material controls.
- Series/anime behavior remains governed by its previous conditions; no TV custom control widget was edited.
- No source extraction engine or movie/TV loader was changed.
- All prior `phases/` documents remain unchanged. This report is added as Phase 23.

## Validation

- Static check confirms the movie branch no longer exposes the standalone HD action in the bottom row.
- Static check confirms a separate CineStream Quality entry remains in `overflowMenuCustomItems` for both mobile and TV menu paths.
- Only `lib/screens/common/player.dart` and this Phase 23 report (copied into `phases/`) were changed.
- ZIP structure and CRC integrity are verified.

Flutter/Dart SDK is not available in this editing environment. `flutter analyze`, automated tests, and `assembleProdRelease` were not run. The labelled layout itself still requires visual confirmation on the same device/build configuration; this fix removes the exact extra action identified by the screenshots and restores the Phase 17 rule without hand-editing the player UI.
