
CINESTREAM-PRO-N — Sequential source queue and playback startup recovery
Scope
This is a changed-files-only patch. It does not include the full application project. Copy the included paths over the matching paths in the existing CINESTREAM-PRO-N repository.

What changed
The source engine registry now exposes onSourceStart, invoked only when a provider is actually dequeued and begins resolving.
UnifiedSourceService.search now resolves providers in manifest priority order, one source at a time. The former split Future.wait between Stremio and non-Stremio groups has been removed. IMDb enrichment is requested only when the queue reaches an add-on that requires an IMDb ID.
ProviderLoader no longer marks every provider as loading before execution. The UI loading callback is wired to the actual source-start event.
Movie and TV loader calls no longer request four concurrent unified provider operations.
Once a source returns an extracted HTTP stream, the current queue is cancelled instead of continuing to scan the remaining sources. If BetterPlayer cannot initialize playback, the new 25-second startup watchdog uses the existing recovery chain: another link, one refresh of the current provider, then the next provider.
Player logs now record only safe diagnostics (provider, host, inferred format, and header names), not signed URL query strings.
A registry test verifies that the sequential queue starts providers in priority order and keeps peak HTTP request concurrency at one within the queue.
Expected behavior
The UI should show a loading spinner only for providers that have actually started. Queued providers remain idle.
The normal direct-source queue is sequential. When the existing 8-second fallback head-start expires, there can be at most one active direct attempt and one active fallback attempt; it will not start all installed providers together.
The first extracted stream is handed to BetterPlayer. If it remains uninitialized/buffering for 25 seconds, playback recovery attempts another link/provider automatically.
Changed files
lib/video_providers/unified/source_engine.dart
lib/video_providers/unified/unified_source_service.dart
lib/video_providers/provider_loader.dart
lib/screens/movie/movie_video_loader.dart
lib/screens/tv/tv_video_loader.dart
lib/screens/common/player.dart
test/video_providers/stremio_addon_provider_test.dart
Verification limits
Static source inspection and archive checks were performed. Flutter/Dart are not installed in this editing environment, so flutter analyze, flutter test, and an Android Release build were not executed. This patch addresses the confirmed concurrent-start UI behavior and adds runtime fallback for a stream URL that never initializes; it does not prove that a specific provider URL (such as Jett) is reachable or valid. The next Release run should be checked for [PlaybackStartup][DATA_SOURCE], [PlaybackStartup][BUFFER_TIMEOUT], and [PlaybackRecovery][NEXT_PROVIDER] logs.

