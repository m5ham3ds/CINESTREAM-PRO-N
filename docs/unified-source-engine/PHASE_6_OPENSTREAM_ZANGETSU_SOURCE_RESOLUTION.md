# PHASE 6 — OpenStream / Zangetsu Source Resolution and Playback Integration

**Project:** CINESTREAM-PRO-N  
**Scope:** Existing project only. No project rebuild or broad reference-project merge.  
**Build target retained:** Debug / `prod` / Android `arm64-v8a` / local mode.

## 1. Evidence from the latest device screenshot

The playback resolver displayed 19 candidates for the movie `Verity` and showed `vidking-direct · Multi` while resolving. This proves repository discovery and provider enumeration reached the playback loader, but it does not prove any API returned a playable URL. The screenshot does not show HTTP status codes or the provider exception, so an exact remote-service failure cannot be inferred from the screenshot alone.

## 2. Confirmed integration defects and corrections

### 2.1 OpenStream fallback metadata was discarded

OpenStream's manifest marks Web Embed entries with a top-level `fallback: true`. `SourceManifest` did not preserve this flag, so the player could not distinguish direct/API providers from slower Web Embed compatibility providers.

Changes:
- Added `SourceManifest.isFallback`.
- Preserved the root-level flag in `SourceRepositoryParser`.
- Preserved it when Stremio manifest enrichment creates a replacement source model.
- Kept the Vidking WebView compatibility provider in the fallback stage.
- Added parser assertions against the checked-in OpenStream repository fixture.
- Ordered playback as direct providers, independent VixSrc, then deferred Web Embed / compatibility providers. The stage resolver searches each stage with bounded concurrency and records a result per source.

The source catalog remains intact; this only changes when a provider is called during playback.

### 2.2 Anime-only providers were included in movie searches

The OpenStream index declares Anikoto, Re:Anime, AnimePahe, FourAnimo and AnimeGG as anime engines. Those engines require anime/episode identity and are not candidates for a TMDB movie such as `Verity`.

Changes:
- Movie playback filters those anime-only engine types before starting the race.
- TV/episode playback retains them.
- The movie loader records how many candidates it filtered.

This avoids spending requests and progress time on a media type those providers cannot resolve.

### 2.3 Web Embed behavior differed from OpenStream

The existing Android bridge had several measurable differences from `WebEmbedResolver.kt`:
- It used `MIXED_CONTENT_NEVER_ALLOW`; OpenStream permits mixed HTTP media inside its isolated embed WebView.
- Plain-HTML hoster scanning only inspected `src` / `href`-style attributes; OpenStream scans quoted absolute URLs because links can be stored in player JavaScript or JSON configuration.
- Metadata-captured stream URLs did not always receive the embed's default User-Agent, Referer and Origin headers.
- Redirect handling did not guard the API-24-only `WebResourceRequest.isRedirect` API.

Changes:
- Matched OpenStream's mixed-content behavior only in the embed player WebView. The separate Cloudflare clearance probe remains strict.
- Matched the broad quoted-URL hoster scan, then validates HTTP(S), host and user-info before accepting candidates.
- Tightened the hoster allowlist check to exact domains or valid subdomains instead of substring matching.
- Passed Referer, Origin and User-Agent into QuickJS hoster extraction.
- Added default User-Agent / Referer / Origin to captured media and subtitle options, while preserving allowed request headers and cookies.
- Guarded `isRedirect` for Android API 24+.
- Retained response-body JSON metadata parsing, URL extraction, quality/header propagation and player-start nudging.

### 2.4 Failure visibility was insufficient

Previously the progress UI could show only that a provider had failed, without exposing the useful failure reason. The Vidking decoder could also produce an empty result without explaining whether `sources` was empty or the optional master playlist was absent.

Changes:
- Vidking now reports HTTP status, source-entry count, master-playlist presence and any configured quality filter when the decrypted response contains no usable stream.
- The loader logs source name, engine, direct/fallback stage, result count, elapsed time and a redacted error message.
- Batch-level repository/storage failures are reported as a stage failure and do not abort the independent VixSrc attempt.
- The loading chips expose the sanitized provider error in a tooltip.
- Query URLs and token / seed / key values are redacted from diagnostic logs.

### 2.5 Vidking Direct protocol comparison

The CINESTREAM-PRO-N implementation was compared with OpenStream's `VidkingDirectApi.kt` and `VidkingPayloadCipher.kt`.

The request contract matches in the important fields:
- `GET /seed?mediaId=<TMDB ID>`.
- Configured relative route such as `cdn/sources-with-title`.
- `title`, `mediaType`, `year`, `episodeId`, `seasonId`, `tmdbId`, `imdbId`, `enc=2`, `seed`, `_t`, and optional `language`.
- Vidking Referer / Origin / User-Agent and no-cache request headers.
- Application-level encrypted payload decoding and the same `sources` / `playlist` / `subtitles` response contract.

No cipher or request-field mismatch was established in this comparison. The patch therefore does not invent a different encoding scheme or change the Vidking cryptography. The remaining uncertainty is the live API's response for each route/title; the new diagnostics will distinguish HTTP errors, empty decrypted source arrays, and invalid payloads.

### 2.6 Zangetsu QuickJS comparison

The runtime contract was compared with Zangetsu's `JsProvider` / `VideoSource` implementation:
- `getInfo()` metadata.
- `search(query, page, {category})`.
- `getDetail(url, {category})` / `getEpisodes(url, {category})` for episodic media.
- `getVideoSources(episodeUrl, fast)`.
- `VideoSource` URL, label, quality, container, headers, audio kind/language, subtitle tracks and timing offsets.

The current CINESTREAM-PRO-N call shape and mapper already match these fields. A mapper test covers Zangetsu-style output and verifies that headers, quality, audio language and subtitles survive conversion.

The screenshot's 19 candidates are OpenStream manifest extensions, not Zangetsu JavaScript source providers. Therefore QuickJS is not the demonstrated cause of the Vidking/Web Embed failures in that screenshot. No Cloudflare Turnstile automation or access-control bypass was introduced.

## 3. APK-size report interpretation

The uploaded size report identifies the APK as **82.98 MiB** and confirms that the native ABI set is already **arm64-v8a only**.

Compressed category sizes reported:

| Category | Size |
|---|---:|
| Flutter/assets | 41.55 MiB |
| Native libraries | 18.84 MiB |
| DEX bytecode | 18.22 MiB |
| Android resources | 3.74 MiB |

Largest entries reported:
- `assets/flutter_assets/kernel_blob.bin`: 32.33 MiB compressed. This is a major Debug/JIT payload; removing it would require changing away from the requested Debug build.
- `libflutter.so`: 14.06 MiB compressed; retained as the Flutter runtime.
- `libVkLayer_khronos_validation.so`: 4.34 MiB compressed. This is an optional Khronos validation/debug layer, not the Flutter video runtime. The Android packaging configuration now excludes this exact file only.
- The QuickJS runtime is approximately 0.45 MiB compressed and is retained.

No player, QuickJS or core Flutter library was removed. The next CI size report must confirm the actual saving; no smaller final APK size is claimed before that build.

## 4. Files changed in this phase

- `lib/video_providers/unified/source_manifest.dart`
- `lib/video_providers/unified/source_repository_parser.dart`
- `lib/video_providers/unified/source_repository_client.dart`
- `lib/video_providers/names.dart`
- `lib/video_providers/provider_loader.dart`
- `lib/video_providers/unified/openstream_web_embed_engine.dart`
- `lib/video_providers/unified/vidking_direct_provider.dart` (diagnostic / seed refresh behavior retained from current phase work)
- `lib/video_providers/unified/quickjs_source_engine.dart` (empty-result diagnostics retained from current phase work)
- `android/app/src/main/kotlin/com/m5ham3ds/cinestreampron/streaming/OpenStreamWebEmbedBridge.kt`
- `android/app/build.gradle` (excludes the validation layer only)
- `lib/widgets/provider_loading_widget.dart` (per-source error tooltip retained)
- `test/video_providers/source_repository_parser_test.dart`
- `test/video_providers/unified/quickjs_stream_mapper_test.dart`

## 5. Validation and limitations

Static checks completed in the available editing environment:
- Parsed the official OpenStream extension index and checked the expected 9 direct Vidking / 10 deferred Web Embed / 1 compatibility fallback classification.
- Parsed the checked-in 30-entry repository fixture.
- Parsed `.github/workflows/android-ci.yml`.
- Parsed all 47 Android XML files.
- Checked the changed-source markers for fallback staging, WebView headers and guarded redirect handling.

Not run in this environment:
- `flutter analyze`.
- `flutter test`.
- Android Gradle / Kotlin compilation.
- A new APK build or live playback against the external providers.

Flutter, Dart and Gradle executables are not installed in this editing environment. The patch is therefore not represented as a completed live-playback verification. A GitHub Actions build and a device test are still required. When a source fails, long-pressing its chip shows the sanitized diagnostic; the CI log also contains `[PlaybackSources][ATTEMPT]` entries for each source.
