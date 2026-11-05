# Phase 11 follow-up — complete quality accumulation and cache resume

## Quality aggregation rule

1080p, 720p, and 480p are completion thresholds only. They are not a whitelist. Every non-empty playable link in each successful provider response is forwarded to the player and retained with its provider identity, URL, quality label, headers, format, adaptive-height metadata, subtitles, and expiry information. A response containing 1080p + 360p + 270p + 180p keeps all four. A response containing 480p + 360p keeps both.

When the third standard height is found, the scanner stops scheduling providers that have not started. It does not cancel providers already in flight. The scan awaits those workers, and their complete results are merged before the session completes. Thus no extra quality returned by a request already underway is lost just because the target was reached during that request.

Adaptive HLS/DASH links retain all positive `availableHeights`; those heights count toward the standard target when present. Bare numeric quality labels such as `270` and `180` are recognized for ordering and height detection, in addition to their `p`-suffixed forms.

## Cache restoration

For movies and TV episodes, a valid cached selection is returned first. At the same time, a supplemental scan is started for eligible providers that have no reusable cached result. Previously cached provider results are supplied as `initialResults`, so their quality heights seed the target:

- If cached results already contain 1080p, 720p, and 480p, the supplemental session schedules no provider requests.
- If one or more standard heights are missing, only providers absent from the reusable cache are scanned.
- New results flow through the normal player scan-update listener and are persisted with the rest of the discovered providers.

Manual provider selection remains scoped to the provider(s) explicitly passed to the loader. Download flows continue to use their existing fresh-resolution path and do not reuse playback cache.

## Build-log fixes

- Added the missing `MediaIdentity` import to both movie and TV loader files.
- Changed the undefined `providerIndex` reference to the loop's actual `index` in the legacy `loadFirstSuccessful` path.

## Added regression coverage

- Keep every quality in provider responses, including 360p, 270p, and 180p.
- Keep full results from requests already in flight when the three-height target is reached.
- Seed scan completion from restored cache results.
- Avoid starting supplemental providers if restored cache already satisfies the standard target.
- Keep duplicate resolutions from different providers as separate selectable entries.

## Verification limitation

This environment has no Flutter or Dart executable. The project archive includes the source changes and tests, but does not claim that `flutter test`, `flutter analyze`, or Android Release assembly ran successfully. Those checks remain to be run by CI.
