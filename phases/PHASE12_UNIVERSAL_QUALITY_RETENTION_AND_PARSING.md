# Phase 12 — Universal video-quality retention and resolution parsing

## Purpose and correction

This phase clarifies and hardens the quality rule established in Phase 11. The earlier numeric example was a typo; the intended familiar lower quality is **360p**. More importantly, the rule is not limited to 360p or to any fixed list of lower resolutions.

**1080p, 720p, and 480p are the only quality heights used as the background-scan completion target. They are not a whitelist, minimum, or filter.** Any valid quality returned by a provider must remain available, including resolutions below 480p, above 1080p, unusual heights, and adaptive-stream renditions.

## Final quality behavior

- A provider response is passed to the player with every playable link it contains. The scanning layer does not select only the best link or trim the response to 1080p/720p/480p.
- Examples retained from one response include `1440p`, `1080p`, `720p`, `480p`, `360p`, `270p`, and `180p` together. The same pass-through rule applies to other valid heights and provider-specific labels.
- A response containing only `1080p` and `360p` keeps both entries and does not satisfy the three-height completion target. Scanning continues for the missing `720p` and `480p` heights.
- A response containing `480p` and `360p` keeps both. The lower resolution is not discarded because a higher one exists.
- If another provider returns a quality already present, its separate URL remains selectable under that provider. Equal resolution does not mean equal source; headers, format, expiry, subtitles, provider identity, and URL remain associated with their own entry.
- Once all three target heights are represented, no additional providers are scheduled. All providers already in flight are awaited; their entire result lists are merged, including any lower, higher, or unusual qualities returned after the target was reached.
- When a cached selection is restored, its cached qualities seed the same completion target. A supplemental scan only searches providers without reusable cached results when one or more target heights are still missing.

## Resolution parsing changes

`VideoUtils.videoQualityHeight` is now the shared parser used by both quality ordering/selection and `ProviderScanSession` target detection.

It recognizes:

- Explicit labels such as `180p`, `270p`, `360p`, `480p`, `1080p`, `1440p`, `2160p`, and `4320p`.
- Dimension labels such as `1920x1080`.
- Numeric labels without the `p` suffix, including `180`, `270`, and numeric heights outside the former fixed list.
- Provider labels with a leading numeric resolution followed by codec/audio details, such as `270 H.264 | AAC`.
- Common shorthand labels such as `QHD`, `4K/UHD`, and `8K` for sorting and preferred-quality matching.

Explicit bitrate labels such as `AAC 128 kbps` are not interpreted as video resolution. This avoids confusing audio bitrate metadata with a video height.

## Files changed in this phase

- `lib/functions/video_utils.dart` — shared broad resolution parser, non-`p` numeric support, common shorthand mapping, and bitrate guard.
- `lib/video_providers/provider_loader.dart` — scanner target detection now delegates to the same parser used by the player, avoiding separate and inconsistent resolution allow-lists.
- `lib/video_providers/unified/vidking_direct_provider.dart` — adaptive-master rendition ranking and available-height extraction use the same shared parser.
- `test/video_utils_test.dart` — tests for 180p/270p, arbitrary lower and higher heights, shorthand labels, bare numeric labels, bitrate exclusion, and sorting.
- `test/provider_background_scan_test.dart` — tests that 1440p/360p/270p/180p survive together, that lower/higher qualities do not falsely complete the target, and that late in-flight responses retain all their entries.
- `PHASE11_PROVIDER_SCAN_QUALITY_AND_CACHE.md` and `PHASE11_QUALITY_ACCUMULATION_AND_CACHE_RESUME.md` — corrected the previous mistaken lower-quality example so the phase history is consistent.

## Acceptance criteria

- No quality is dropped merely because it is not 1080p, 720p, or 480p.
- Every playable link in a completed provider response is forwarded and preserved.
- All results from already-started provider requests are collected before the scan completes.
- Duplicate qualities from different providers remain distinct selectable sources.
- Only the presence of 1080p + 720p + 480p stops scheduling additional providers.
- Resolution ordering and scan-target detection use the same parsing rules.

## Verification status

Source-level review and regression tests were updated in this phase. Flutter/Dart SDK is not installed in the editing environment, so `dart format`, `flutter analyze`, `flutter test`, and Android Release assembly could not be executed here. This report does not claim a successful APK build. Run the project's Release GitHub Actions workflow and inspect its result before installing.

## Phase numbering

This is **Phase 12**, following the Phase 11 provider-scan/cache work. Future follow-up changes must create a new report under `phases/` with the next sequential phase number (Phase 13, Phase 14, and so on); do not keep appending unrelated follow-ups to Phase 11.
