
Unified Source Engine — Player Integration Continuation
Status: source-to-player selection and mirror recovery implemented in the working tree; Flutter compilation and live playback still require validation on the Android device.

This continuation is limited to CINESTREAM-PRO-N. The OpenStream, Zangetsu, and FlixQuest archives were not modified. No project rebuild or architecture migration was performed.

1. Confirmed player integration gap
The unified search adapter already converted each playable UnifiedStreamOption into a separate RegularVideoLinks item. The conversion retained the stream URL, provider name (server), quality/audio label, HLS/DASH indicator, request headers, and subtitle URLs/headers. VideoUtils then generated stable unique keys for same-quality mirrors and used those keys for the URL, format, header, and download-token maps.

The visible source selector was still provider-level only: it listed the aggregate Unified Sources provider and the direct VixSrc provider. It did not enumerate the individual links already returned by Unified Sources. Consequently, extension discovery and successful extraction could occur without giving the viewer a visible per-server choice.

This is a confirmed UI/data-flow mismatch. It does not, by itself, prove why any particular extracted URL fails to play; that requires the runtime diagnostics and a current device test.

2. Changes in this continuation
Player source selection
The mobile player source sheet now lists the actual unified stream results, with each result showing its server/provider name, quality/audio label, container type, and whether request headers are attached.
The Android TV provider menu now exposes the same individual unified stream choices.
Selecting a stream selects its exact stable resolution key in BetterPlayer while retaining the other returned mirrors in the resolution map.
The chosen stream's provider identity is used for the player display/analytics and current-provider download label rather than always reporting the aggregate Unified Sources label.
The original provider-level choices remain available for VixSrc and for re-resolving the unified provider.
Recovery after a failed mirror
The player records the active unified stream URL and its source name.
When the current unified stream enters the existing source-recovery path, the player first tries an unused mirror from a different server, then another quality from the same server.
Once the currently known mirrors are exhausted, the unified provider can be re-resolved once for the failed URL to obtain fresh signed links. Per-URL refresh tracking prevents an unbounded retry loop.
The selected URL's request headers and explicit HLS/DASH metadata remain aligned with its exact map key during selection and recovery.
This fallback is a code-path implementation. It is not claimed as proven playback until the BetterPlayer error/recovery callback is exercised against real network streams on the device.

Diagnostics and tests added
ProviderLoader now logs safe aggregate search diagnostics: repository/catalog/installed counts, attempt and successful-source counts, playable stream count, converted player-link count, subtitle count, and per-source engine/result counts. Full stream URLs and header values are not logged.

Added tests:

test/video_utils_test.dart: verifies the public stable-key list matches the source-link order, including duplicate qualities across servers.
test/video_providers/unified_legacy_adapter_test.dart: verifies provider identity, quality, HLS metadata, request headers, and subtitle headers survive the unified-to-player adapter; also verifies expired and unplayable streams are not offered as playable results.
3. Build configuration
Updated .github/workflows/android-ci.yml to pass --target-platform android-arm64 while retaining:

Debug build;
prod flavor and lib/main.dart target;
ENABLE_FIREBASE=false;
LOCAL_DEV_MODE=true;
the existing output artifact name CINESTREAM-PRO-N-apk.apk.
No --split-per-abi option was added. The workflow's existing APK copy/rename step remains in place. No dependency versions, native libraries, Firebase settings, or download implementation were changed.

4. Files changed
lib/screens/common/player.dart
lib/video_providers/provider_loader.dart
lib/functions/video_utils.dart
test/video_utils_test.dart
test/video_providers/unified_legacy_adapter_test.dart (new)
.github/workflows/android-ci.yml
docs/unified-source-engine/PHASE_4_PLAYER_INTEGRATION_STATUS.md (this report)
No files were intentionally deleted. Repository ingestion, engine registration, QuickJS, WebView bridge, Vidking, Stremio, anime engines, and download implementation were not rewritten in this step.

5. Validation status and remaining device check
The editing environment does not contain flutter or dart, so dart format, flutter analyze, flutter test, and an Android build could not be run here. The new tests are included but unexecuted. The GitHub Actions build and actual APK generation therefore remain to be confirmed by the next workflow run.

On-device validation should check the following in order:

Open a movie or episode and open the player source menu. Individual unified-source servers should appear instead of only the aggregate Unified Sources row.
Select a server/quality entry. Confirm the player loads and that sources requiring Referer/User-Agent headers are passed with the selected link.
Cause or encounter a failed stream and confirm that the player tries a different server before requesting fresh unified results.
Capture log lines beginning with [UnifiedSources][SEARCH], [UnifiedSources][ATTEMPT], [UnifiedSources][PLAYER_SELECT], and [UnifiedSources][PLAYER_RECOVERY] if playback still fails.
Interpretation of the new search diagnostics:

installedEnabled=0 or attempts=0: the repository/install/engine selection stage did not supply runnable sources.
attempts>0 but successfulSources=0 or playableStreams=0: extraction or media identity resolution did not return a usable direct stream.
playableStreams>0 but playerLinks=0: the stream-to-player adapter rejected the returned results.
playerLinks>0 followed by player errors: extraction reached the player; the remaining issue is likely URL reachability, request headers, container/codec support, or a host-side playback restriction and must be diagnosed from the actual error.
No live source is marked working based only on being listed in the catalog. No playback success is claimed until the device test completes.

