# CINESTREAM-PRO-N — Provider scan, cross-source qualities, and playback reuse

## Scope

This phase updates the existing Flutter project in place. It does not replace provider engines or copy OpenStream implementation code into the app. OpenStream is used as a behavioral reference; CINESTREAM keeps its own Dart engines, TMDB identity, player, and provider adapters.

## OpenStream findings applied

- The official `extensions/index.json` distinguishes Vidking Direct, Web Embed, Anime Site, and Stremio engines. The `Multi` language label is not a media-capability declaration; tags and engine type determine support.
- OpenStream's Web Embed entries such as Jett, Sage, Sova, Phoenix, Reyna, Viper, Skye, Astra, Harbor, and Gekko declare `movies`, `series`, and `fallback` tags. The `fallback` tag is significant even when there is no top-level `fallback: true` property.
- Anime Site engines (Anikoto, Re:Anime, AnimePahe, FourAnimo, AnimeGG) are anime-only. OpenStream's anime mapping resolves TMDB episode identity through AniList/AniZip mapping rather than assuming that every TV episode is an anime.
- OpenStream's default search gives direct providers a head start and releases Web Embed fallbacks after 8 seconds, or earlier when all direct providers finish without a playable result.
- Vidking may return an adaptive master playlist and a list of its available renditions. An adaptive master can expose several quality heights without requiring separate provider URLs.
- OpenStream's `ResolvedStreamCache` is memory-only with a 10-minute TTL and forgets failed links. CINESTREAM intentionally uses secure persistent storage for the requested cross-session reuse, but retains per-link expiry and invalidation rather than copying the 10-minute in-memory design.

## CINESTREAM changes

1. Provider discovery preserves individual source identities. Each result remains associated with its original provider, URL, quality, headers, subtitles, adaptive metadata, and expiry.
2. Playback starts on the first usable provider result. A bounded background scan continues to collect alternate links and qualities.
3. The scanner stops scheduling *new* providers when it has found 1080p, 720p, and 480p, or when all eligible sources have been exhausted. These three heights are a stop condition only, never a quality whitelist. Every quality returned by a provider is retained, including resolutions above 1080p, 360p, 270p, 180p, 288p, unusual heights, and provider-specific labels. When the target is reached, requests already in flight are allowed to finish and their complete result sets are merged before the scan closes.
4. Web Embed sources marked with the `fallback` tag are deferred. Direct sources receive an 8-second head start; fallbacks start sooner if direct sources finish without a playable result. A reserved worker allows fallbacks to start at the head-start deadline even when direct requests remain slow.
5. Source support is evaluated per media identity. Anime-only engines are not invoked for ordinary movies/live-action series; multi-content engines remain eligible for the media categories they declare.
6. TV episode identity carries the anime flag through episode selection and next-episode navigation. TMDB genre/language metadata is retained in TV models and bookmark persistence so watchlist entry points do not silently turn anime into generic live-action series.
7. Resolved provider links and the last successfully initialized URL are stored in Android secure storage. The cache is keyed by media type, TMDB ID, season, episode, and anime classification.
8. Each URL keeps its original discovery timestamp. Adding a newly discovered provider or quality does not extend the lifetime of older cached URLs. Explicit source expiry is honored, and a failed URL is invalidated individually without deleting other qualities/providers.
9. Cached playback is tried before a new search. If the selected URL fails during player initialization or later playback recovery, it is invalidated and the existing recovery chain can resolve a fresh link.
10. On a cache hit, the last valid URL starts playback immediately while a supplemental scan checks only eligible providers that have no reusable cached result. Cached links seed the three-height target; if all three heights are already present, no further provider requests are scheduled. If some are missing, the supplemental scan runs in the background and streams newly discovered provider results into the player.

## Tests added

- Background scanning returns the first playable provider while the scan remains active.
- Scanning stops scheduling new sources after all three standard heights are found, while preserving every link in the complete results of already-started requests.
- Restored cache qualities seed the scan target, and only providers missing reusable cached results are scanned after immediate playback restoration.
- Duplicate resolutions from different servers remain separate selectable entries; 360p/270p/180p and lower qualities are retained rather than filtered out.
- Anime-only providers are skipped for ordinary movies.
- Deferred Web Embed fallback behavior observes the direct-source head start.
- Playback cache round-trips provider links, headers, subtitles, and the last working URL.
- Invalidating one URL preserves other qualities and providers.
- Updating a cache with a newly discovered provider does not refresh the timestamp of an older URL.
- Anime metadata classification is covered for Japanese animation and non-Japanese animation controls.

## Verification status

The source archives were inspected and the patch was reviewed against the OpenStream engine/index behavior. The editing environment does not have Flutter or Dart installed, so `dart format`, `flutter analyze`, `flutter test`, and an Android Release build could not be executed here. The project ZIP therefore contains source-level changes and tests, not a claim of a verified APK build. Run the existing Release workflow before installing this build.
