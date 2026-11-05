# PHASE 13 — Live Quality Catalogue & Playback Source Stability

**Project:** CINESTREAM-PRO-N  
**Base:** Complete Phase 12 project snapshot  
**Status:** Source changes and regression tests added; Flutter test/build execution pending in an environment with the Flutter SDK.

## 1. Reported behavior

The supplied playback screenshots showed a mismatch between the two selectors:

- The provider selector listed multiple concrete results from Jett, Sova, Phoenix and other sources, including fixed qualities and adaptive HLS/DASH entries.
- The Quality selector showed only `Auto · 540p`.
- During playback, the visible quality changed from a lower rendition to an adaptive 540p rendition. The screenshots alone did not prove that a different provider had been activated; the active row was labelled `Auto` and `HLS`, which is also consistent with an adaptive rendition change inside the current manifest.
- The user required background discovery to add choices only. It must not replace the active URL/provider merely because a new source or quality was discovered.

## 2. Root cause fixed: Unified Sources entries were omitted from the quality catalogue

`PlaybackQualityCatalog.collect` previously skipped the entire `unified:sources` bucket because it was treated as a synthetic aggregate-only mirror. In this project that bucket can also contain the real results returned by the Unified Sources engine (for example, Jett/Sova/Phoenix entries with their own `server`, URL, format and headers). Skipping the whole bucket removed those real choices from the Quality sheet, leaving only the active player’s native adaptive `Auto` entry.

The collector now reads every provider bucket, including `unified:sources`, and removes only exact mirrored duplicates using the provider identity, URL, quality, format, request headers and available adaptive heights. Equal resolutions from different providers remain separate choices.

## 3. Quality selector behavior

- The native BetterPlayer quality button is disabled for this view because its resolution map describes only the currently active data source.
- The app's Quality action opens a dedicated catalogue built from all provider-owned results collected by the player.
- Every concrete result remains independently selectable, including multiple links at the same resolution from different providers.
- HLS/DASH adaptive options remain available for the currently active source. An adaptive master is displayed with all `availableHeights` reported by its provider.
- Selecting a catalogue row is an explicit user action. It activates that specific provider/link and preserves its own format, headers, size token and provider subtitles.
- Merely receiving a background scan result never calls `setupDataSource`, never changes `_activeStreamUrl`, and never changes `_currentProviderCode`. This invariant is asserted in debug builds and logged as `[PlaybackScan][CATALOG_ONLY]`.
- The Quality bottom sheet listens to catalogue revisions while open, so it can add newly discovered choices without requiring the user to close and reopen it.

## 4. Scan result delivery and completion visibility

A fast provider could finish after `startScan` began but before `PlayerOne` attached its stream listener. The scan session now keeps a replayable `resolvedResults` snapshot. The player merges this snapshot during initialization, then listens for subsequent updates. This prevents early completed results from disappearing from the picker due to route-construction timing.

The scan session also exposes the number of requests already in flight. Once 1080p, 720p and 480p are all known, no new provider requests are scheduled; however, every request that had already started is allowed to finish and its complete response is added to the catalogue. The Quality sheet reports when the target has been reached but already-started requests are still finishing.

The three standard heights remain scan-completion thresholds only. They are not a filter. Any other detected quality—including 2160p, 1440p, 360p, 270p, 180p, uncommon numeric heights, or additional variants in an adaptive manifest—continues to be retained.

## 5. Manual source selection and cached playback

Manual first-provider selection continues to honor the user's choice for initial playback. The supplemental scan then checks other eligible providers. Cached playback results are loaded into the catalogue immediately, and missing providers are scanned in the background. Scan results completed before the player's subscription are recovered from the session snapshot.

## 6. Distinguishing adaptive rendition changes from provider failover

A quality change inside one HLS/DASH URL is not the same as a provider switch. Diagnostics now separate these cases:

- `[PlaybackAdaptive][RENDITION_CHANGED]` / `[PlaybackAdaptive][RESOLUTION_CHANGED]`: adaptive resolution changed inside the active stream; includes the active stream key and provider label.
- `[PlaybackRecovery][AUTOMATIC_FAILOVER_TRIGGER]`: playback recovery was invoked after a startup/buffering failure.
- `[PlaybackRecovery][AUTOMATIC_FAILOVER]`: recovery is actually moving from one provider to another.
- `[PlaybackScan][CATALOG_ONLY]`: a new discovery result was added without changing the active stream.

This makes a future device log sufficient to determine whether a visible 360p-to-540p change was adaptive selection, a user-selected source change, or actual error recovery. It avoids treating a screenshot alone as proof of a provider switch.

## 7. Regression coverage added

- Unified Sources real results are visible in the global quality catalogue.
- Mirrored aggregate links are deduplicated without hiding the original.
- Equal resolutions from separate providers remain separate choices.
- Adaptive entries retain all advertised rendition heights.
- Expired links are excluded.
- Provider results completed before the player subscribes remain accessible through the scan snapshot.
- In-flight requests remain counted after the standard quality target is reached and are collected before scan completion.
- Non-standard and above-1080p qualities remain present while the scan continues toward the 1080p/720p/480p target.

## 8. Files changed

- `lib/video_providers/quality_catalog.dart`
- `lib/video_providers/provider_loader.dart`
- `lib/screens/common/player.dart`
- `lib/screens/movie/movie_video_loader.dart`
- `lib/screens/tv/tv_video_loader.dart`
- `assets/translations/en.json`
- `assets/translations/ar.json`
- `assets/translations/es.json`
- `assets/translations/hi.json`
- `test/quality_catalog_test.dart`
- `test/provider_background_scan_test.dart`
- `phases/PHASE13_LIVE_QUALITY_CATALOG_AND_SOURCE_STABILITY.md`
- `README_CHANGED_FILES.txt`

## 9. Validation status

- Translation JSON syntax: validated.
- Source review and regression-test additions: completed.
- Flutter/Dart formatting, `flutter test`, analyzer and Android Release build: not run because Flutter/Dart SDK is not installed in this editing environment.
- Device playback behavior: not yet re-tested on the user's handset.

Run the repository's existing Release GitHub Actions workflow before installing this snapshot. After installation, test one fixed MP4 source and one adaptive HLS/DASH source, and inspect the diagnostic tags above if the active source appears to change without a user action.
