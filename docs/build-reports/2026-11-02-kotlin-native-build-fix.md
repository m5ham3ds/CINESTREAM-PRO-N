# Kotlin native build fixes — 2026-11-02

## Build errors addressed

### 1. `DisguisedSegmentDataSource` is `internal`

`StreamDownloadStore` previously imported an implementation detail from the `better_player_plus` Android module. Kotlin correctly rejected access to that `internal` class from the application module.

The app now owns `DisguisedHlsSegmentDataSource`, a Media3 `DataSource` adapter used only for HLS downloads. It preserves the disguised-segment behavior without reaching into the player module's internal API. It recognizes:

- Plain MPEG-TS (passed through unchanged).
- MPEG-TS appended after a PNG `IEND` chunk.
- MPEG-TS in WebP `EXIF` payloads.
- `TIKTIKRAW` and `TIKTIKTSGZ` payload markers.
- `TIKTIKPX` data encoded in PNG RGB pixels and gzip-compressed.
- A prefixed TS payload when the MPEG-TS sync pattern is valid.

The adapter leaves playlists, byte-range requests, ordinary keys, and unrecognized media untouched. It caps in-memory segment buffering at 32 MiB and decompression at 64 MiB. Recognized but malformed wrappers fail with an `IOException` rather than being passed to the demuxer as if they were valid media.

### 2. `languageGuess` unresolved in `OpenStreamWebEmbedBridge`

`CapturedResource` is a nested data class and cannot call a private instance method on its containing bridge. The helper was moved into `CapturedResource`, where subtitle mapping invokes it from the correct scope.

## Tests added / checked

- Extended `DownloadCacheReuseTest` for WebP EXIF-wrapped segments.
- Extended `DownloadCacheReuseTest` for gzip-marked `TIKTIKTSGZ` segments.
- Existing tests continue to cover plain TS, PNG-trailer payloads, `TIKTIKRAW`, and malformed/error responses.
- Ran an isolated Kotlin compiler smoke check for the new adapter against Java-shaped Media3/Android API stubs.
- Ran executable smoke cases for plain TS, raw marker, gzip marker, PNG trailer, and WebP EXIF. All passed.

## Validation limitation

This workspace does not have the Android SDK/Flutter build environment and could not run the full `:app:compileProdDebugKotlin` or `flutter build apk` task. The next GitHub Actions run is required to confirm compilation against the exact AndroidX Media3 and Android SDK artifacts.

The AndroidX/legacy-support references in Media3 and Cast shown in the prior workflow log were warnings, not the cause of the Kotlin compilation failure; dependency versions were not changed as part of this fix.
