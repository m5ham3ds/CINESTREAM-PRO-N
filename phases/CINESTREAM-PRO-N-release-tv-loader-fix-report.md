
CINESTREAM-PRO-N — Release TV loader compile fix
Exact build error
GitHub Actions failed during :app:compileFlutterBuildProdRelease because TVVideoLoader called _showErrorSheet() at three sites but _TVVideoLoaderState did not define it.

Fix
Added _showErrorSheet(String message) to lib/screens/tv/tv_video_loader.dart, following the matching behavior in movie_video_loader.dart. Retry recreates the TV loader with the same arguments.

OpenStream movie-support clarification
OpenStream does support movies. The supplied screenshots show Verity playing through Jett. The official fixture in CINESTREAM declares Jett's movieUrl as https://vidlink.pro/movie/{tmdbId} and its TV route separately. The movie loader already keeps Vidking Direct, Stremio, and Web Embed sources eligible; it excludes only anime-specific providers. Tests now assert Jett's movie URL, TV URL, tags, fallback flag, and beta status.

Preserved build configuration
Release stays the default; Debug remains selectable from manual workflow dispatch. Flavor prod, ARM64-only single APK, local mode flags, APK name, and existing dependencies remain unchanged.

Validation
Static declaration/call-site checks: passed.
OpenStream manifest fixture assertions added: source verified.
Workflow configuration inspection: passed.
Flutter Analyze/Test and actual Release build: not run here (Flutter/Dart unavailable).
