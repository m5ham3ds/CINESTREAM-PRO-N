# Unified Source Engine — Phase 3 Status

**Status:** engine integrations implemented; static validation completed; Flutter/Dart compilation and live playback remain unverified.

Phase 3 extends the Phase 2 repository and playback integration. The supplied FlixQuest archive remains the project base. OpenStream and Zangetsu archives were inspected as read-only references; their original files were not edited.

## 1. OpenStream official repository coverage

The checked-in fixture was taken from the OpenStream repository format and contains 30 extension entries. The parser recognizes all entries and maps them into the following engine families:

| OpenStream engine family | Entries in the fixture | Runtime implementation | Platform / limits |
|---|---:|---|---|
| `vidking-direct` | 9 | `VidkingDirectSourceEngine` | Direct API resolver with seed refresh and encrypted-envelope validation |
| `stremio` | 5 | `StremioSourceEngine` | Direct HTTP(S) streams only; torrent, YouTube and external-page links are not playable in this adapter |
| `web-embed` | 10 | `OpenStreamWebEmbedSourceEngine` | Android WebView capture plus direct hoster extraction |
| `vidking-webview` | 1 | `OpenStreamWebEmbedSourceEngine` | Android WebView capture using the Vidking embed routes |
| `anikoto` | 1 | `OpenStreamAnimeSourceEngine` | Anime episode mapping and Anikoto AJAX / MegaPlay or hoster extraction |
| `reanime` | 1 | `OpenStreamAnimeSourceEngine` | Anime episode mapping and ReAnime / MegaPlay source decryption |
| `animepahe` | 1 | `OpenStreamAnimeSourceEngine` | AnimePahe search, session handling and Android WebView clearance for ordinary `cf_clearance`; interactive Turnstile is not automated |
| `fouranimo` | 1 | `OpenStreamAnimeSourceEngine` | Sub/dub episode streams, subtitle tracks and intro/outro metadata |
| `animegg` | 1 | `OpenStreamAnimeSourceEngine` | AnimeGG episode and MP4 variant resolution |
| **Total** | **30** | **All nine raw engine labels are mapped** | Live service availability is not implied |

`SourceRepositoryParser` keeps unknown engine types visible as unsupported metadata. The source manager only enables an entry for execution when its engine has a registered implementation and the source is installed/enabled.

## 2. Web-embed and hoster extraction

`OpenStreamWebEmbedSourceEngine` first inspects the embed page for supported hoster iframe/link URLs and tries the bundled QuickJS extractor registry. When direct extraction does not produce streams, it calls the Android channel `flixquest/openstream_web_embed`.

The native `OpenStreamWebEmbedBridge` uses a short-lived, isolated WebView and captures HTTP(S) HLS, DASH, MP4/WebM media URLs and supported subtitle URLs from resource requests and page fetch/XHR activity. The bridge returns the captured URL with useful request headers (Referer, Origin, User-Agent and Cookie) and associated subtitle tracks. It destroys the WebView after success or timeout and does not return the HTML embed page as a playable stream.

Bundled hoster extractors currently include DoodStream, Filemoon, MP4Upload, OK.ru, Streamlare, StreamWish, Vidmoly and Voe, plus the shared template/example. Host domains change frequently; the presence of an extractor does not guarantee that a host remains operational.

The bridge accepts HTTP(S) page navigation only. It does not attempt to defeat interactive challenge systems, CAPTCHAs or DRM. Cloudflare clearance is attempted only for the AnimePahe integration and only when an ordinary browser clearance cookie is issued; interactive Turnstile remains unsupported.

## 3. Zangetsu-compatible JavaScript runtime

The new QuickJS layer is split into:

- `JsEngine`: Android isolate-backed Flutter JS runtime with a serialized call queue;
- `QuickJsProviderRuntime`: script loading, bounded provider calls, fetch/crypto/timer/console channels and bundled extractor registration;
- `QuickJsSourceEngine`: Zangetsu-style video provider contract adapter;
- `quickjs_stream_mapper.dart`: conversion of returned video-source objects into `UnifiedStreamOption` values.

The adapter calls `getInfo()` to validate provider type, uses `search()` for title matching, resolves episodes from `getDetail().episodes` when present and falls back to `getEpisodes()`, then invokes `getVideoSources(episodeUrl, false)`. It preserves direct stream URLs, quality, container, request headers, audio kind/language, subtitle tracks and their headers, subtitle offsets, expiry hints, proxy hints and descriptive DRM metadata. It never extracts DRM keys or bypasses a licence system.

Provider scripts are not auto-executed merely because they appear in a repository. They must be installed, enabled and backed by a supported JavaScript engine. The runtime enforces HTTP(S)-only URLs, rejects localhost and private/link-local IP literals, caps script/response size and provider/network timeouts, and revalidates the final URL after HTTP redirects. This is a constrained extension runtime, not a claim that arbitrary third-party scripts are fully sandboxed against every possible network or resource attack; only trusted repositories should be installed.

Zangetsu's currently disabled generic Cloudflare auto-solve behavior was not re-enabled. A JS provider flag such as `browser: true` does not silently launch a challenge solver. AnimePahe's dedicated path is separate and documented above.

## 4. Stremio manifest compatibility improvement

The parser now reads `types` and `idPrefixes` declared either at the Stremio manifest root or inside the `resources` entry named `stream`. It also treats `behaviorHints.configurationRequired` as requiring add-on configuration, just like `configurable`. This prevents the app from sending a movie/series ID to the wrong resource or guessing an ID scheme when the manifest explicitly declares one.

Stremio direct-stream handling still intentionally excludes torrent hashes, YouTube entries, external player pages and add-ons that require user-specific configuration until their separate debrid/configuration or external-host engines are implemented.

## 5. Phase 3 changed files

Compared with the Phase 2 deliverable:

- 25 files added;
- 14 existing files modified;
- 0 files deleted.

New files include the QuickJS runtime and provider adapter, OpenStream anime and WebView engines, Android WebView bridge, bundled hoster extractors, a 30-entry OpenStream fixture and third-party license notices. The Stremio parser and QuickJS stream mapper received additional edge-case handling and tests.

## 6. Validation

Completed in the available environment:

- Parsed the OpenStream fixture as JSON and confirmed 30 entries across the nine engine labels listed above.
- Checked that every bundled extractor asset referenced by the runtime exists and is included under the Flutter assets directory.
- Checked repository/parser/runtime registration consistency and Android MethodChannel name consistency.
- Compared the Phase 3 tree against the Phase 2 ZIP: 24 added, 12 modified, zero deleted.
- Ran Zangetsu's original JavaScript harness: 54 tests total, 41 passed, 13 skipped (all skipped tests require live network access), zero failed. This validates the *reference project's JS contracts and extractors*, not the Dart/Flutter port itself.
- Added Flutter unit tests for stream metadata preservation and Stremio stream-resource prefixes.

Not run:

- `flutter pub get`, `dart format`, `flutter analyze`, `flutter test`;
- Android Gradle/APK build;
- end-to-end runtime tests on a physical Android phone/TV;
- live playback checks for the 30 OpenStream sources or arbitrary Zangetsu repository providers.

The editing environment does not contain Flutter or Dart executables. Therefore this deliverable is implementation-complete at the source level but is not yet build-verified or live-provider-verified. The next validation must run with Flutter 3.35.7 / Dart 3.9+ and include a device test for each engine family.

## 7. Next work

1. Run dependency resolution, Dart formatting/analyzer and the complete Flutter test suite on Flutter 3.35.7.
2. Build and test on an Android phone and Android TV, especially the off-screen WebView bridge lifecycle and returned media headers.
3. Test each OpenStream engine family with current, working sources; refresh or disable any upstream entry that has changed.
4. Add user-facing ID enrichment for Stremio add-ons that require AniList/Kitsu/MAL IDs when the metadata providers make those identifiers available.
5. Replace the transitional BetterPlayer link-label adapter with a first-class source/audio/subtitle selector and integrate unified downloads only after expiry and header handling are tested.
