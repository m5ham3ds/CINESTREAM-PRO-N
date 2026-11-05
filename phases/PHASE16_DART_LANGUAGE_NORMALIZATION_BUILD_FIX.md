# PHASE 16 — Dart Language Normalization Build Fix

## Goal

Fix the `assembleProdRelease` compilation failure reported by GitHub Actions (`Flutter 3.35.7` / Dart 3.9.x) without changing subtitle-provider behavior or the Arabic-default subtitle policy introduced in Phase 15.

## Root cause

Dart does not support the bitwise `|` operator as an alternative-pattern separator in a `switch` expression. Phase 15 used forms such as:

```dart
'ara' | 'arabic' => 'ar',
'eng' | 'english' => 'en',
```

The analyzer/compiler therefore emitted both “binary operator | is not supported as a constant pattern” and “operator '|' isn't defined for String”. The same invalid pattern had been copied into four language-normalization helpers.

## Changes

Replaced the invalid switch alternatives with ordinary boolean comparisons in all four locations:

- `lib/screens/common/player.dart`
- `lib/screens/common/player/player_external_subtitles.dart`
- `lib/services/external_subtitle_service.dart`
- `lib/services/subtitle_playback_store.dart`

The normalization behavior is unchanged:

- `ara` and `arabic` normalize to `ar`.
- `eng` and `english` normalize to `en`.
- Other language codes are preserved after the existing lowercase/trim/prefix normalization.

Added a regression case to `test/subtitle_playback_store_test.dart` confirming that human-readable `Arabic` and `English` language names restore as `ar` and `en`. Existing tests continue to cover the ISO-639-2 `ara` code and Arabic OpenSubtitles search/download normalization.

## Scope protection

- No subtitle provider, endpoint, API-key requirement, or download flow was changed.
- Arabic remains the preferred/default subtitle language as configured in Phase 15.
- Earlier phase reports remain in the root `phases/` directory and are retained unchanged.

## Validation

- Searched `lib/` and `test/` for the invalid string-pattern form; no remaining occurrences were found.
- Confirmed all four language-normalization helpers now use valid boolean comparisons.
- Added a focused language-alias regression test.
- Flutter/Dart SDK is not installed in the artifact workspace, so `flutter test` and `flutter build apk --release` could not be run here. A new GitHub Actions `assembleProdRelease` run is still required to confirm compilation in the project's configured Flutter environment.

## Files changed

- `lib/screens/common/player.dart`
- `lib/screens/common/player/player_external_subtitles.dart`
- `lib/services/external_subtitle_service.dart`
- `lib/services/subtitle_playback_store.dart`
- `test/subtitle_playback_store_test.dart`
- `phases/PHASE16_DART_LANGUAGE_NORMALIZATION_BUILD_FIX.md`
