# Unified Source Engine — Phase 2 Status

**Historical status:** Phase 2 is superseded by [Phase 3](PHASE_3_STATUS.md). The implementation now includes the OpenStream engine families and Zangetsu-compatible QuickJS runtime described there.

This phase builds on `PHASE_0_1_STATUS.md`. The FlixQuest archive remains the base project. The OpenStream and Zangetsu source archives were used as read-only references.

## 1. Movie and episode playback integration

- `movie_video_loader.dart` and `tv_video_loader.dart` now offer `Unified Sources` before the direct VixSrc fallback for ordinary playback.
- The old remote provider-discovery request to `FlixQuest Scraper API v2` is no longer called from the movie/episode loader, provider chooser, or TV provider-order dialog.
- Each movie or episode is converted to a `MediaIdentity` before source resolution. The episode identity includes series TMDB ID, season, episode, and episode TMDB ID when available.
- `ProviderLoader` routes the unified provider to `UnifiedSourceService`; VixSrc remains an independent fallback.
- The current BetterPlayer boundary is preserved. The adapter converts each stream into a distinct legacy link and adds provider/audio labels to the resolution label so same-quality mirrors are not overwritten by the old quality-keyed map. Request headers, HLS/DASH flags, and subtitle URLs/headers are passed through.
- Download mode is intentionally not wired to the unified engine yet. It retains the existing direct-provider boundary until expiry, downloadability, and file-transfer metadata are handled explicitly.

## 2. OpenStream Vidking Direct engine

Added `VidkingDirectProvider` and `VidkingPayloadCipher`, adapted from the MIT-licensed OpenStream Vidking implementation.

- Supports the OpenStream `vidking-direct` engine type and the relative routes present in its repository.
- The API origin is fixed to the documented Vidking API host; repository entries can select an allowed relative route but cannot replace the host.
- Requests a media-specific seed, caches it for the server-provided TTL, and retries once after HTTP 401 with a refreshed seed.
- Decrypts and integrity-checks the response envelope, then maps direct sources, adaptive playlist, quality, subtitles, language hints, and request headers into `UnifiedStreamOption`.
- Does not bypass DRM or implement licence/key extraction.

## 3. Stremio engine and repository manager

- Stremio direct-stream add-ons remain executable through their `/stream/{type}/{id}.json` endpoint.
- Direct HTTP(S) streams and request/subtitle headers are preserved. Exact duplicate entries are removed without collapsing distinct mirrors or track metadata.
- Torrent hashes, YouTube links, and external embed pages are not treated as direct playable streams.
- Repository catalog data is cached in memory for five minutes to avoid downloading the same index and add-on manifests on every play attempt. Explicit refresh forces a re-fetch; add/remove/import invalidates the catalog cache. Installed state is recomputed from the cached catalog, so install/uninstall takes effect immediately.
- A failed forced refresh retains the last known catalog if the entire refresh fails, while exposing the latest repository errors.

## 4. Source manager UI

Added `SourceRepositoriesScreen` and navigation entry points in mobile Settings and TV Settings. It supports:

- adding the official OpenStream index or another HTTP(S) repository;
- listing and removing repositories;
- viewing source metadata and support status;
- installing/uninstalling sources whose engine is registered;
- exporting and importing repository/install configuration.

Unsupported engines are visible but cannot be installed for execution yet. This is deliberate: a visible manifest must not imply its script/engine is runnable.

## 5. Zangetsu repository compatibility

The parser now understands the Zangetsu-compatible root `sources` list and resolves each `.js`/`.mjs` file and optional logo relative to the repository URL. It stores provider type, version, and runtime contract metadata without downloading or evaluating source scripts.

**QuickJS execution is not implemented in Phase 2.** No remote JavaScript source is executed. The install control remains disabled for JavaScript entries until a constrained runtime, fetch/console/crypto/timer bridge, extractor dispatch, cancellation, and timeout behavior are ported and tested in a later phase.

## 6. Remaining legacy boundaries

The VOD discovery path no longer depends on the private FlixQuest provider catalog. The `ScraperApi` class remains in the codebase because unrelated integrations and download-related utilities still reference the configured API URL. Live TV, advertisements, size estimation, and other existing app services were not removed or rewritten as part of this phase.

The player continues to use FlixQuest's BetterPlayer integration. This phase does not yet provide a separate per-stream UI for all audio/subtitle tracks, and subtitle offset / expiry / proxy metadata is not fully represented by the legacy player adapter.

## 7. Dependency and validation status

The supplied archive referenced `../flixquest-betterplayer`, which was absent. `pubspec.yaml` points to the public FlixQuest-maintained Git package instead. The package's current manifest requires Dart 3.9+ and Flutter 3.35+; this project pins Flutter 3.35.7 in `.fvmrc`. `pubspec.lock` still needs to be regenerated by `flutter pub get` for the Git dependency.

Static checks performed in the editing environment:

- all translation JSON files parse;
- `pubspec.yaml` parses;
- relative Dart imports in the changed source files resolve;
- movie/episode loader and provider-precedence UI no longer call the old provider discovery method;
- compared with the original FlixQuest archive: 22 files added, 19 modified, and 0 deleted.

**Not performed:** `flutter pub get`, `dart format`, `flutter analyze`, `flutter test`, Android build, or live provider playback. The environment used to prepare this archive did not contain Flutter or Dart executables. The added unit tests therefore remain unexecuted.

## Superseded work items

The QuickJS runtime, OpenStream web-embed engines, and five OpenStream anime engines were added in Phase 3. Remaining work is to run Flutter/Dart validation, test all engine families live on Android, enrich external IDs for Stremio add-ons, and upgrade the player/download boundary as documented in [PHASE_3_STATUS.md](PHASE_3_STATUS.md).
