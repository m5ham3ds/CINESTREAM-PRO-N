> Historical note: Phase 0/1 is superseded by [PHASE_3_STATUS.md](PHASE_3_STATUS.md), which documents the current engine integrations and remaining validation work.

# Unified Source Engine — Phase 0/1 Status

**Status:** foundation implemented; existing playback screens have not yet been migrated.

This phase starts replacing the closed FlixQuest Scraper API dependency without
removing the existing playback path prematurely. The original project archive
is not modified; these changes are made in the extracted working copy.

## What changed

### 1. Player dependency recovery

`better_player_plus` previously pointed to a sibling directory that is not
included in the supplied FlixQuest archive. `pubspec.yaml` now points to the
public FlixQuest-maintained Git repository instead. Run `flutter pub get` to
regenerate `pubspec.lock` and resolve the Git dependency. The Git repository
is licensed separately under Apache-2.0 and currently declares Flutter 3.35+ / Dart 3.9+ as its minimum SDK.

### 2. Unified media identity

`lib/video_providers/unified/media_identity.dart` introduces a single identity
for movies, series episodes, and anime episodes. TMDB remains the catalogue ID;
IMDb/Stremio and other external IDs are stored separately. A TMDB integer is
not guessed to be an IMDb or Stremio ID.

### 3. Unified stream option

`stream_option.dart` represents each stream as a separate object. It preserves
its provider, URL, quality, dimensions, container, HTTP headers, audio kind and
language, subtitle tracks and headers, subtitle offsets, expiry, proxy metadata,
and descriptive DRM scheme. It deliberately does not contain DRM keys or
implement licence bypasses.

### 4. Repository ingestion

`source_repository_parser.dart` understands:

- OpenStream-style repository documents with inline `extensions`;
- raw extension arrays;
- linked `extensionLists` documents;
- direct Stremio `manifest.json` links.

Invalid individual entries are skipped rather than causing a valid repository
to disappear. Unknown engines remain visible as unsupported metadata. The OpenStream
official index currently includes multiple engine families; in this phase only
the Stremio family is registered for execution. The index can be added manually
from `https://raw.githubusercontent.com/Ivorisnoob/OpenStream/main/extensions/index.json`,
but entries for unported engines will remain listed as unsupported.

`SourceRepositoryClient` downloads HTTP(S) repository documents, resolves
relative linked-list paths, tolerates a broken linked list, and enriches Stremio
entries from their `/manifest.json` documents to learn supported content types
and identifier prefixes. `SourceRepositoryManager`
persists user-added repository URLs and supports configuration import/export. It
keeps a full catalog separate from the installed-and-enabled source list:
repository entries honor their `installedByDefault` flag, while other entries
remain catalog-only until installed. A direct Stremio manifest URL explicitly
added by the user is installed by default. Removing a repository also clears
its stored install/disable preferences.

### 5. First executable source engine: Stremio direct streams

`StremioAddonProvider` requests the add-on stream endpoint and accepts only
explicit direct HTTP(S) stream URLs. It passes request headers from
`behaviorHints.proxyHeaders.request`, stream headers, subtitle tracks, and
subtitle headers through to `UnifiedStreamOption`.

Torrent `infoHash` items, YouTube entries, and external-page links are not
reported as playable. There is no torrent/debrid integration in this phase.

### 6. Engine registry and facade

`SourceEngineRegistry` supports bounded concurrent resolution with results
returned in source-priority order and an optional progressive callback.
`UnifiedSourceService` combines repository refresh, source resolution, and
stream deduplication while keeping distinct mirrors that require different
headers.

### 7. Legacy compatibility

`LegacyProviderResultAdapter` converts existing FlixQuest `ProviderLoadResult`
objects to the new model without collapsing same-quality mirrors. Transitional
methods were added to `ProviderLoader` so the old scraper/VixSrc results can be
mapped while the player migration is prepared.

## Deliberately not activated yet

The existing movie and TV loading screens still use the legacy provider flow.
The new service is not yet wired into those screens or the player. Repository
management and source install/uninstall methods exist as Dart APIs, but a user-facing
repository/extension manager screen has not been added yet. This avoids changing
player behavior before the stream-to-player adapter and UI source picker are
implemented and tested.

The following engine families are parsed and retained as metadata but are not
yet executable:

- OpenStream `vidking-direct`, `vidking-webview`, `web-embed`, and its site-specific
  anime engines;
- Zangetsu JavaScript/QuickJS provider scripts;
- CloudStream, Mihon, and other native extension runtimes.

The runtime registry currently registers only the Stremio direct-stream engine.
A repository entry cannot execute arbitrary JavaScript merely because it exists
in an index. The QuickJS runtime and its HTTP/extractor bridge must be ported,
constrained, and tested separately before those sources can be enabled.

## Build and test status

Automated Dart/Flutter validation was not run in this environment because the
Flutter and Dart executables are unavailable. The project lockfile must be
regenerated by `flutter pub get` after the Git dependency change. The new tests
are under `test/video_providers/` and should be run with `flutter test` followed
by `flutter analyze` in a Flutter 3.35-compatible environment.

## Next implementation phase

1. Wire the unified source service into movie and episode loaders alongside
   the legacy provider path, with an explicit feature flag during validation.
2. Add the OpenStream Vidking direct engine and its response/decryption model.
3. Port Zangetsu's JavaScript runtime in a separate isolated module, preserving
   per-provider identity, bounded requests, cancellation, timeouts, and safe
   extractor dispatch.
4. Implement the stream-to-player adapter and replace the quality-keyed map
   with a list of selectable stream options.
5. Add source selection, fallback, subtitle and audio controls to the unified
   player UI. Only then remove the legacy scraper dependency from movie/TV
   playback; keep unrelated API uses (such as Live TV) isolated until reviewed.
