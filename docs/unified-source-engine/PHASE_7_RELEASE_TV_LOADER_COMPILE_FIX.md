# Phase 7 — Release compile fix and OpenStream movie support clarification

## Build failure addressed

The Release compile failure in `lib/screens/tv/tv_video_loader.dart` was caused by three calls to `_showErrorSheet()` without a corresponding method in `_TVVideoLoaderState`.

The TV loader now defines `_showErrorSheet(String message)`, matching the established movie-loader error-sheet behavior. It:

- captures the current TV metadata and playback options before popping the loader route;
- opens `ReportErrorWidget` with the original localized error;
- retries by pushing a new `TVVideoLoader` with the same metadata, download mode, TV-player mode, exit callback, and ad stage.

This resolves the three undefined-method references reported by `compileFlutterBuildProdRelease`. A Flutter Release build still needs to be run by GitHub Actions because Flutter/Dart are unavailable in the editing environment.

## OpenStream movie support — correction

OpenStream does support both movies and series. The supplied screenshots show the OpenStream app playing the movie `Verity` through Jett, including a running timeline and playback settings.

The official manifest fixture in this project also declares Jett as:

- `tags: [movies, series, fallback, official]`
- `fallback: true`
- `engine.type: web-embed`
- `movieUrl: https://vidlink.pro/movie/{tmdbId}`
- `tvUrl: https://vidlink.pro/tv/{tmdbId}/{season}/{episode}`

The CINESTREAM movie loader already passes a `UnifiedMediaType.movie` identity and does not filter out Vidking Direct, Stremio, or Web Embed providers. Its movie-only filter excludes only the five anime-specific engines: Anikoto, Re:Anime, AnimePahe, FourAnimo, and AnimeGG. The parser test now explicitly protects Jett's movie template and its fallback/beta status.

`status == 3` is OpenStream's beta status, not a down status. The repository layer correctly excludes only status `0` from playback attempts.

## Build mode and packaging preserved

- GitHub Actions default: Release.
- Manual workflow dispatch: Release or Debug.
- Flavor: `prod`.
- Target: `lib/main.dart`.
- `ENABLE_FIREBASE=false` and `LOCAL_DEV_MODE=true`.
- ARM64-only single APK; no `--split-per-abi`.
- Output artifact name remains `CINESTREAM-PRO-N-apk.apk`.

## Validation status

Static checks confirm the TV loader now has one method declaration for the three call sites, the Jett fixture assertions match the checked-in OpenStream manifest, and the Release-default workflow remains in place. `flutter analyze`, `flutter test`, and an actual Release APK build were not run in this environment.
