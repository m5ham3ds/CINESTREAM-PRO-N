
PHASE 8 — OpenStream / Zangetsu integration audit and playback-path corrections
Project: CINESTREAM-PRO-N
Scope: source identity, content-type routing, source scheduling, anime episode mapping, Stremio identifiers, QuickJS contract and player hand-off
Build policy: Release by default; Debug remains a manual GitHub Actions choice; ARM64-only single APK
Reference projects inspected selectively: OpenStream-beta and Zangetsu-main

1. Executive result
OpenStream is a unified streaming system. Its repository contains providers for movies, series and anime; each provider declares or implements the media types it can resolve. It is not accurate to describe OpenStream as a movie-only or anime-only application.

The review found several integration gaps in CINESTREAM-PRO-N that could prevent an installed source from receiving a usable identity or being tried at the right time:

TMDB external IMDb identifiers were available in catalogue/details code, but they were not enriched into the media identity at the unified playback boundary. This particularly affected Stremio add-ons whose manifest uses the default IMDb prefix.
Deferred fallback sources waited for the full direct-source batch. OpenStream gives direct sources an eight-second head start, then starts fallback providers if no direct result has arrived.
The unified playback loader could receive per-source results progressively but still wait for the whole direct batch before returning a playable provider to the player.
Anime mapping required the same TMDB-to-AniList separation and season/episode/date matching used by OpenStream. The cache key also needed to distinguish a movie TMDB ID from a TV TMDB ID, because their numeric namespaces overlap.
When a Stremio add-on required an ID prefix for which the current title had no identifier, the adapter could return an empty result without explaining the missing identity.
The source code has been updated for these specific gaps. This is a code-level integration correction; it is not a claim that every remote provider currently returns a working stream. The actual network endpoints and playback still need a Release build and live-device verification.

2. The end-to-end contract
TMDB catalogue identity
        |
        +--> Movies: movie TMDB ID + title + year
        |
        +--> Series: TV TMDB ID + season + episode + episode TMDB ID/date
        |
        +--> Anime: TV/movie TMDB ID + AniList/MAL mapping + episode identity
        |
        v
Provider-specific identity preparation
        |
        +--> Stremio: advertised idPrefixes; IMDb lookup only if required
        +--> Vidking Direct: TMDB ID, mediaType, season/episode, optional IMDb
        +--> Web Embed: movieUrl OR tvUrl with its placeholders
        +--> OpenStream anime sites: TMDB -> ani.zip -> AniList sequel/episode map
        +--> Zangetsu JS: getInfo -> search -> detail/episode -> getVideoSources
        |
        v
Provider execution and host extraction
        |
        v
UnifiedStreamOption
(url, container, headers, audio, subtitles, expiry, metadata)
        |
        v
Legacy player adapter
(RegularVideoLinks + subtitle/header metadata)
        |
        v
BetterPlayerDataSource
(url + matching headers + HLS/DASH format + subtitles)
The adapter continues to preserve the same URL/header association when the player turns stream options into its existing RegularVideoLinks map. BetterPlayer remains the player engine; no player replacement was made.

3. Content types: what is supported and how it is routed
Content	Identity passed to providers	OpenStream-style provider families	CINESTREAM routing
Movie	movie, TMDB movie ID, title, year, optional external IDs	Vidking Direct, Stremio movie, Web Embed movieUrl, JavaScript providers declaring movie/`all`; anime providers only where ani.zip explicitly maps the TMDB movie as MOVIE	MediaIdentity.movie; Stremio protocol type movie; QuickJS category movie; anime-film mapping uses AniList episode slot 1
TV series	series, TMDB TV ID, season, episode, episode ID/date, external IDs	Vidking Direct, Stremio series, Web Embed tvUrl, JavaScript providers declaring tv/`series`/`anime`/`all`	MediaIdentity.series; Stremio protocol type series with :season:episode; QuickJS category sub; episode URL resolved before extraction
Anime series	anime, TMDB TV ID, season, episode, AniList/MAL IDs when known	OpenStream anime-site providers, Stremio add-ons advertising relevant IDs/types, JavaScript anime providers	Anime site engine maps TMDB to AniList and episode; QuickJS uses the provider's anime contract and sub category
Anime movie	movie, TMDB movie ID, optional AniList ID	Anime site provider only when ani.zip says MOVIE; compatible JavaScript movie/all providers	AniList root is resolved and episode slot 1 is supplied to anime sites; it is not treated as ordinary S1E1
A provider is not filtered just because its repository contains anime-related extensions. The manifest's content types, the engine implementation and the actual identity supplied to that engine determine whether it is applicable.

4. OpenStream findings mapped to CINESTREAM-PRO-N
4.1 Stremio and TMDB -> IMDb mapping
OpenStream reference files

app/src/main/java/com/ivor/openstream/data/streaming/IdMappingService.kt
app/src/main/java/com/ivor/openstream/data/streaming/providers/StremioAddonProvider.kt
OpenStream checks each add-on's idPrefixes. With no declared prefixes, Stremio's default identifier is IMDb. If the add-on explicitly advertises TMDB, the TMDB identifier can be used; IMDb is not guessed for an add-on that only accepts another prefix. OpenStream stores TMDB-to-IMDb results for 30 days and keeps an expired cached mapping as an offline fallback for a limited period.

CINESTREAM gap found

MediaIdentity already had an externalIds map and an IMDb accessor.
TMDB external-ID endpoints already existed in lib/api/endpoints.dart.
But the movie and TV playback identity factories did not obtain IMDb at the point where the unified source service needed it.
StremioAddonProvider correctly respected prefixes, so a default IMDb-only add-on could receive no candidate ID even though the title had a TMDB ID.
Changes made

Added lib/video_providers/unified/media_identity_resolver.dart.
The resolver requests /movie/{id}/external_ids or /tv/{id}/external_ids only when the selected Stremio source requires IMDb.
It validates identifiers as tt followed by digits, merges them into a new immutable MediaIdentity, coalesces simultaneous requests for the same media, and uses the existing TMDB HTTP cache policy (30-day freshness plus bounded stale lifetime).
UnifiedSourceService.search() starts non-Stremio sources immediately while the optional IMDb lookup runs, then sends the enriched identity only to the Stremio branch that needs it.
Existing IMDb, AniList and other external IDs are preserved.
When an add-on accepts no supplied identifier, StremioAddonProvider now returns a diagnostic naming the accepted prefixes instead of silently returning an empty list.
idPrefixes beginning with tt are treated consistently with OpenStream's IMDb-prefix test.
4.2 Web Embed and fallback providers
OpenStream reference files

app/src/main/java/com/ivor/openstream/data/streaming/ExtensionProviderRegistry.kt
app/src/main/java/com/ivor/openstream/data/streaming/StreamingRepositoryImpl.kt
docs/EXTENSIONS.md
OpenStream keeps Web Embed and other deferred providers in a fallback stage. Direct providers start first. Fallback providers start as soon as all direct providers have returned empty, or after FALLBACK_HEAD_START_MS = 8_000 if direct providers are still pending.

CINESTREAM gap found

The provider loader separated fallback providers, but it awaited the complete direct-source batch before starting the fallback batch.
A slow WebView/direct provider could therefore hold up the fallback sources beyond OpenStream's intended head-start window.
Results could be reported progressively, but the caller still awaited the full direct batch before returning its first playable provider.
Changes made

ProviderLoader now starts direct sources immediately and arms an eight-second fallback timer.
If all direct sources finish without a playable stream, fallback starts immediately.
If no direct result arrives by eight seconds, fallback starts while direct sources continue.
The first playable result returned by a stage is now passed to the player immediately; the associated CancelToken stops requests that are no longer needed.
If a direct source wins before fallback returns, the fallback stage is cancelled. If fallback returns first after its head start, it can be selected rather than waiting indefinitely for a slow direct source.
Each source keeps its own progress/result callback and its direct/fallback stage is included in diagnostics.
Not yet ported from OpenStream: remembered last-working provider with its separate 10-second head start, the persistent resolved-stream cache, and the five-failure circuit breaker with cooldown. These are separate optimization/resilience features and are intentionally listed as remaining parity work rather than claimed as completed.

4.3 Anime episode mapping
OpenStream reference file

app/src/main/java/com/ivor/openstream/data/streaming/anime/AnimeEpisodeMapper.kt
The reference mapper:

Requests ani.zip by TMDB ID and checks whether the returned mapping is a movie or TV entry.
Loads the AniList root entry and its ani.zip episode mappings.
For a TV series, walks the AniList SEQUEL chain, up to a bounded depth.
Matches TMDB season/episode against ani.zip's seasonNumber/`episodeNumber`.
Uses the TMDB episode air date as a fallback.
Uses sequential episode numbering only for S1 when the AniList episode count makes that safe.
For an anime film, supplies AniList episode 1.
Coalesces concurrent mapping work for the same episode, and does not cache transient network/cancellation failures.
CINESTREAM changes made

The anime engine now uses a cache key containing the media type as well as TMDB ID, season and episode, so movie/42 cannot collide with tv/42.
Concurrent requests for the same mapping share an in-flight operation. This matters because multiple anime providers can request the same episode in one search.
Movie mappings are accepted only when ani.zip reports MOVIE; the anime provider receives AniList episode 1.
TV mappings walk AniList sequel relations and match season/episode coordinates.
If direct coordinates do not match, the engine checks the supplied episode air date and can retrieve TMDB season metadata to find the relevant air date.
Sequential fallback remains limited to S1 and the known episode count.
A definitive no-match may be cached; network exceptions are not cached.
4.4 Vidking Direct
OpenStream reference file

app/src/main/java/com/ivor/openstream/data/streaming/providers/VidkingDirectApi.kt
The CINESTREAM and OpenStream implementations were compared for:

fixed Vidking API host and /seed request;
source route plus title, mediaType, year, episodeId, seasonId, tmdbId, imdbId, enc=2, seed, and cache-buster query fields;
request User-Agent, Referer, Origin, and no-cache headers;
401 seed refresh;
response decryption;
handling of sources, subtitles, and master playlist;
selecting the master HLS playlist when no quality filter is applied.
The inspected code paths match in these key parts. No source evidence justified changing the cipher or inventing an alternate encoding. The current diagnostic now includes HTTP status, source entry count, master playlist presence and quality-filter context when decryption succeeds but no usable URL is produced.

4.5 Zangetsu QuickJS contract
Zangetsu reference material

providers/_template.js
providers/allanime.js
js_harness/contract.test.mjs
js_harness/host.mjs
extractor scripts in extractors/
The playback contract is:

getInfo() identifies the provider type and metadata;
search(query, page, {category}) returns candidate media rows;
getDetail(url) may include episodes;
getEpisodes(url) is an alternate episode-list path;
getVideoSources(episodeOrMediaUrl, fast) returns source objects;
provider scripts may call extractVideo(embedUrl, options) to resolve a hoster into one or more video sources.
CINESTREAM state confirmed

QuickJsSourceEngine calls getInfo, search, getDetail / getEpisodes, and getVideoSources in the playback path.
It resolves series episodes before requesting streams and reports an explicit message if getVideoSources() produces no HTTP(S) stream.
The QuickJS runtime exposes extractVideo and loads the bundled host extractors.
The bundled extractor set includes Doodstream, MP4Upload, OK.ru, Streamlare, Filemoon, Streamwish, Voe and Vidmoly (plus the example extractor). It is not missing the basic extractor files present in the inspected Zangetsu tree.
The HTTP bridge carries method, headers, text body, status, response headers and final URL, with redirect checks and response-size limits.
Remaining Zangetsu parity gaps

getHome() and popular() are discovery/catalogue functions; they are not currently wired into the unified playback screen's source-resolution path.
The current HTTP bridge is text-oriented; it does not provide a full binary/ArrayBuffer response surface.
Zangetsu's VideoSource can carry ClearKey drmKid and drmKey; CINESTREAM's mapper does not pass key material into BetterPlayer, and BetterPlayer's current adapter has not been made ClearKey-capable. No DRM key pass-through was added in this phase.
An installed JS script is not proof that it runs correctly. Each provider still needs an actual getInfo/search/detail/getVideoSources exercise against its live site.
5. Files changed in this phase
File	Change
lib/video_providers/unified/media_identity_resolver.dart	New TMDB external-ID / IMDb enrichment boundary with cache and request coalescing
lib/video_providers/unified/media_identity.dart	Immutable copy helper for merged external IDs
lib/video_providers/unified/unified_source_service.dart	Stremio prefix-aware IMDb enrichment, while non-Stremio engines run without waiting
lib/video_providers/unified/stremio_addon_provider.dart	Clear diagnostic when an add-on's accepted ID prefixes have no matching identifier
lib/video_providers/unified/openstream_anime_engine.dart	Type-aware anime mapping cache, in-flight coalescing, movie mapping and TMDB air-date fallback
lib/video_providers/provider_loader.dart	OpenStream-style eight-second fallback head start and immediate first-playable selection
test/video_providers/unified/media_identity_resolver_test.dart	Tests for movie/TV mapping distinction, TV/anime endpoint use, immutable ID merge, coalescing, TTL and invalid ID rejection
No source repository, reference project, app shell, Firebase integration, media player library, or dependency version was replaced in this phase.

6. Validation status
Static checks completed in the editing environment:

Delimiter/string/comment balance check on all seven modified Dart/test files: passed.
GitHub Actions YAML parse: passed; job build-android present.
Release remains the default for push, pull request and manual workflow. Debug remains a manual workflow_dispatch option.
Build still targets android-arm64, keeps one APK, and does not use --split-per-abi.
No new package dependency was added.
Not executed here:

dart format;
flutter analyze;
flutter test;
flutter build apk --release;
live calls to TMDB, ani.zip, AniList, Vidking, Stremio add-ons, Web Embed pages, or Zangetsu provider scripts;
playback verification on the user's Android phone.
The editing environment does not contain Flutter or Dart. Therefore this phase must not be described as a successful Android build or as proof that all providers currently return playable video.

7. Required live verification after the next Release build
Test a film (e.g. Verity): confirm TMDB movie identity, Vidking direct, Web Embed movieUrl, and Stremio IMDb/TMDB prefix path.
Test a TV episode (e.g. Criminal Minds S1E1): confirm series identity, Stremio :season:episode suffix, Web Embed tvUrl, QuickJS detail/episodes, and anime mapping only where applicable.
Test one anime series episode and one anime film: confirm ani.zip mapping type, AniList entry and episode number.
Confirm direct sources begin immediately; the fallback stage begins at 8 seconds or sooner when all direct sources finish empty; first playable source starts without waiting for all other sources.
For every selected source, verify the exact URL, HLS/DASH/MP4 detection, request headers, and subtitle headers reach BetterPlayer.
Retain [PlaybackSources][ATTEMPT], [PlaybackSources][SELECTED], [PlaybackRecovery] and QuickJS logs for any failed source. The original HTTP status or extractor error is needed to distinguish blocked providers from a player/URL hand-off problem.
8. Next parity steps (not silently marked complete)
Add OpenStream's preferred-last-working-provider behaviour and per-provider circuit breaker after the basic source lifecycle is confirmed.
Add short-lived resolved-source caching if the source identity, headers and expiry can be safely validated.
Add optional Stremio source-link reachability checks with a strict latency budget; avoid delaying Vidking/WebView sources with global URL probing.
Extend QuickJS binary/network response support only if a real Zangetsu provider requires it.
Decide separately whether ClearKey is in scope for the BetterPlayer adapter; do not transfer raw DRM keys without explicit playback support and a safe design.
Expand provider-level integration tests with recorded fixtures, then verify selected live providers on the device.
