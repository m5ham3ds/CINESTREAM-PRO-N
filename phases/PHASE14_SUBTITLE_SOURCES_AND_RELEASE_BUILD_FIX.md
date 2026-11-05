# PHASE 14 — External Subtitle Sources & Release Build Fix

**Project:** CINESTREAM-PRO-N  
**Base:** Complete Phase 13 project snapshot  
**Status:** Source changes and regression tests added; Flutter test/build execution pending in an environment with the Flutter SDK.

## 1. Release build errors fixed

The Phase 13 GitHub Actions log reported three Dart compile errors in `lib/screens/common/player.dart`:

- The video size is nullable. The height read now uses a null-aware access (`size?.height`) so the Quality sheet can render before the player reports dimensions.
- The repository's pinned `better_player_plus` Git fork exposes `setTrack` as a `void` method. The two `await` expressions were removed while retaining the explicit user-selected adaptive track action.

These changes address the exact three compiler diagnostics in the supplied log. A new CI run is still required to confirm the complete Release build.

## 2. OpenStream subtitle audit

The OpenStream project was inspected at its source, not inferred from provider names. Its subtitle flow has three distinct inputs:

1. **Subtitles supplied by the video source itself.** These travel with the selected stream, including their own URL, language, format and request headers. CineStream already carries these through `UnifiedStreamOption.subtitles` and its provider-to-player adapter; this path is preserved.
2. **OpenSubtitles.** OpenStream resolves the TMDB title to an IMDb ID, then queries the legacy `rest.opensubtitles.org` REST search. The default search requests English separately and also requests the unfiltered result list. It supplies both `User-Agent` and `X-User-Agent` as `TemporaryUserAgent`. Search rows provide file ID, download URL, format, language, hearing-impaired flag, download count and release name. Downloaded subtitle payloads are commonly gzip-wrapped.
3. **SubSource.** OpenStream mirrors SubSource's undocumented `api.subsource.net/v1` website API: IMDb search (`/movie/search`) -> title result (`/subtitles/...` or `/series/...`) -> language/season list -> exact-episode filtering -> subtitle detail endpoint -> short-lived `download_token` -> ZIP download. Its rows identify language, release, episode, hearing-impaired status and a detail link. The detail URL is not the final subtitle file URL.

OpenStream searches OpenSubtitles and SubSource concurrently, de-duplicates repeated results and prefers English. These two external catalogues are independent of the subtitles already supplied by the active video stream.

## 3. CineStream implementation

CineStream now keeps its existing Scraper API subtitle search and aggregates it with OpenSubtitles and SubSource:

- The TMDB `external_ids` mapping layer supplies the IMDb ID needed by the two external catalogues. If this mapping is unavailable, their requests are skipped safely and the existing Scraper API can still return results.
- OpenSubtitles searches English and unfiltered results concurrently, applies the required legacy request headers, keeps supported SRT/VTT formats, limits results per language, and preserves release and HI/SDH metadata.
- SubSource searches English plus the selected app language and Android device language when they differ. It filters results to the exact requested language and TV episode, excludes trailers and multi-episode packs, and preserves HI/SDH and release metadata.
- Each catalogue is failure-isolated. An outage, unexpected response, unavailable IMDb mapping or malformed row from one provider does not hide the other providers' results.
- Results are merged by URL and repeated language/release/HI identity while distinct releases remain selectable. The UI labels each result with its source so the user can identify OpenSubtitles, SubSource or the configured Scraper API.
- On selection, OpenSubtitles files are downloaded with their required user-agent headers. SubSource detail pages are first exchanged for the short-lived download token, then the ZIP is fetched. The normalizer detects gzip/ZIP from file signatures rather than trusting a filename.
- SRT, WebVTT, ASS and SSA are normalized to WebVTT in memory before being passed to BetterPlayer. Legacy single-byte subtitle text uses a Windows-1252-compatible fallback, matching OpenStream's handling of older subtitle files.
- A failed subtitle download is isolated to that selected track; other selected subtitle files continue to be processed.

## 4. Compatibility and safety details

- The project uses `archive 4.0.7`. ZIP members are read with `ArchiveFile.readBytes()` rather than relying on the older archive 3.x content representation.
- External subtitle downloads have response-size limits, ZIP entry-count limits, supported-extension checks and rejection of HTML/error pages masquerading as subtitles.
- The existing provider-supplied subtitle path, local subtitle upload path and Scraper API fallback remain intact.
- SubSource is an undocumented third-party API and OpenSubtitles search uses a legacy REST endpoint. Either may change independently; errors are logged and isolated rather than being allowed to break playback or app startup.

## 5. Regression tests added

- OpenSubtitles search resolves the IMDb ID from TMDB and sends the expected request headers.
- SubSource search filters by exact season/episode and does not label a different-language row as the requested language.
- SubSource detail URL is exchanged for a download token and a ZIP containing SRT is extracted and normalized.
- OpenSubtitles gzip download is decompressed and normalized with the required user-agent headers.
- SRT, existing WebVTT, ASS and Windows-1252 legacy punctuation are normalized.
- HTML/error responses are rejected rather than applied as subtitles.
- Existing merge behavior keeps different releases while removing duplicate release records.

## 6. Files changed

- `lib/screens/common/player.dart`
- `lib/screens/common/player/player_external_subtitles.dart`
- `lib/models/external_subtitles.dart`
- `lib/services/external_subtitle_service.dart`
- `lib/services/subtitle_file_normalizer.dart`
- `pubspec.yaml`
- `pubspec.lock`
- `test/external_subtitle_service_test.dart`
- `test/subtitle_file_normalizer_test.dart`
- `phases/PHASE14_SUBTITLE_SOURCES_AND_RELEASE_BUILD_FIX.md`
- `README_CHANGED_FILES.txt`

## 7. Validation status

- OpenStream repository paths for OpenSubtitles, SubSource, combined search and subtitle download/decompression were inspected.
- The three supplied Dart compile errors were corrected in the source.
- Test coverage for search, exact episode/language filtering, token resolution, gzip/ZIP handling and format normalization was added.
- ZIP/project structure and YAML/JSON syntax are checked during packaging.
- Flutter formatting, `flutter test`, analyzer and Android `assembleProdRelease` were **not run** because the Flutter/Dart SDK is not installed in this editing environment.
- Device behavior and live third-party API availability have not been verified on the user's handset. Run the Release GitHub Actions workflow before installation.
