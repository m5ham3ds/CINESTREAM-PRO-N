# Phase 11 — Provider capability classification and seasonal appearance

## Scope

This phase refines the existing CINESTREAM-PRO-N implementation. It does not create a new project or replace the source engine architecture. The full project archive retains the previous Phase 10 playback queue, Release-default Android workflow, ARM64-only APK configuration, and the existing BetterPlayer/QuickJS integrations.

## 1. Source capability classification

The OpenStream `extensions/index.json` supplied with this conversation was inspected directly. Its declarations distinguish general-purpose providers from anime-only providers:

- Yoru, Cypher, Breach, Neon and Vyse advertise `movies` and `series`. They must remain eligible for live-action movies and television.
- Anikoto, Re:Anime, AnimePahe, FourAnimo and AnimeGG advertise `anime`, `sub` and `dub`, without movie/series capability declarations. Their engines are dedicated anime-site engines and are treated as anime-only.
- Web Embed providers such as Jett declare both `movieUrl` and `tvUrl`; they remain eligible for films and series. A source supporting anime as well does not become anime-only merely because it carries an `anime` tag.

`SourceManifest.isAnimeOnly` now considers the engine kind, explicit JavaScript `providerType`, and capability tags. Explicit universal tags (`all`, `multi`, `multi-content`, `universal`, `movies-and-series`) override a generic anime tag. This prevents a multi-content source from being crossed out by a broad tag alone.

For JavaScript providers whose manifest omits the content type, `QuickJsSourceEngine` reads the real `getInfo()` type. If it declares `anime` for a live-action request, the movie/TV loader now transitions that provider to the same muted, struck-through `skipped` state rather than presenting the incompatibility as a random extraction failure. The provider is still available for anime requests.

### Anime feature films

Anime movies stay `UnifiedMediaType.movie` for normal movie routing and AniZip's `MOVIE` mapping. A separate `isAnimeContent` flag allows anime-only sources to be eligible for an anime feature film without misrouting it as a TV episode. Current inference is explicit metadata or TMDB animation genre ID 16 combined with original language `ja`; callers can also pass `isAnime` explicitly. A missing original-language field may prevent inference, so callers with authoritative anime metadata should set the explicit flag.

## 2. Provider queue and UI state

The playback source loader resolves providers in a strict ordered sequence. It calls the start callback only when the next provider actually starts, awaits the current provider result, and stops when a provider returns non-empty video links. Providers that do not support the requested content are skipped before a network request. The loading widget now describes a sequential queue rather than a source race; a skipped provider uses the dimmed/struck-through state, while the active provider uses the spinner.

This is an application-level sequential queue. It is not a live integration test of every remote endpoint; external provider uptime and link quality remain dependent on the provider itself.

## 3. Ambient mode

The Ambient implementation was compared with the supplied FlixQuest source. The core service, route-scoped color lifecycle, and root theme application already match the reference implementation, so they were retained rather than duplicated:

- `AmbientThemeScopeController` attaches to title, season and episode detail routes.
- When enabled, it extracts a dominant color from the title artwork using the existing cached image pipeline.
- The active route color is restored when a route is disposed, and the root theme receives `activeAmbientColor`.
- Extraction is skipped when Ambient mode is disabled; failed image extraction safely leaves the normal theme in place.

Ambient mode remains a user-controlled preference and defaults to off.

## 4. Seasonal themes and seasonal effects

The settings rows were already present but were gated by `occasionalThemeCatalog.enabled`. The app's local/empty bootstrap configuration can supply a disabled catalog after initial preference hydration, which hid both seasonal controls even though the domain model and overlay existed.

`AppDependencyProvider.applyOccasionalThemeCatalog` now uses the built-in local catalog when the bootstrap catalog is disabled or empty. An enabled remote catalog still takes precedence. The local catalog is not persisted with generated date windows, so recurring dates are recalculated on future launches and after the next scheduled boundary.

The local catalog provides manually selectable palettes (Autumn, Winter, Spring, Summer, Christmas, New Year, Valentine's Day, Halloween, Ethiopian New Year, Easter, Eid and Diwali) with configured seasonal effects. Timed automatic activation is used only for presets with fixed Gregorian windows; Easter, Eid and Diwali remain manually selectable because their dates vary by calendar/year. Manual selections resolve before automatic windows. In automatic mode, a manual-only preset does not override Ambient mode outside its timed window.

The Seasonal Effects preference is exposed when the catalog supports effects and controls the existing `OccasionalEffectOverlay`; it does not create a parallel overlay system.

## 5. Tests added or extended

- Anime-only JavaScript `getInfo()` mismatch classification.
- Universal tags prevent an `anime` tag from making a multi-content source anime-only.
- Existing tests for live-action, anime episodes and anime feature films remain in the provider queue test suite.
- Manual seasonal presets remain selectable while automatic mode leaves Ambient mode unobstructed.
- Seasonal effects are enabled for a manually selected local preset.
- A disabled bootstrap catalog falls back to the built-in seasonal catalog.

## 6. Verification status

Static checks in this environment:

- 29 JSON files parsed successfully.
- 16 YAML files parsed successfully.
- 47 Android XML files parsed successfully.
- The `player.dart` Release regression fix remains present; there is no active `VideoPlayerValue.isInitialized` getter use (the name appears only in a comment).
- The project retains the `release` default and `debug` manual workflow option.
- The project retains the `arm64-v8a` single-ABI configuration.

Flutter/Dart SDKs are not installed in this editing environment. Therefore `flutter analyze`, `flutter test` and a Release APK build were not executed here. The new tests are included in the project but still need to run in GitHub Actions or a Flutter environment.
