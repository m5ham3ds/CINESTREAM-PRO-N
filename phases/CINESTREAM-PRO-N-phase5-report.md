
Phase 5 — Individual source providers, playback failover, and app identity
Scope
All changes in this phase are made inside CINESTREAM-PRO-N. Reference projects are not re-audited or copied wholesale. BetterPlayer remains the playback engine; no download implementation or core plugin dependency is removed.

Playback/source changes
Installed manifests are now enumerated as individual VideoProvider entries only when the current SourceEngineRegistry has a runtime registered for that manifest's engine kind.
Each source receives a stable provider code based on its manifest repository URL and ID. The code is used by the source order preference, loading state, error state, player picker, and fallback sequence.
Movie and episode initial discovery tries those installed runnable providers individually, then retains VixSrc Direct as the final standalone fallback. The old aggregate Unified Sources path remains available for compatibility but is no longer the only repository provider presented to the player.
The provider picker and precedence screen use the same individual-source catalogue. Unsupported manifest engine types are not reported as playable merely because they appear in a repository catalogue.
BetterPlayer's existing sourceRecoveryHandler now works against a provider-specific failure set: try an alternate stream from that provider, refresh its extraction once when all returned mirrors are exhausted, then progress through subsequent providers without a retry loop.
Manually retrying a provider that was exhausted discards its stale cached extraction and resolves it again. A fresh provider still reuses its cached result when available.
The legacy adapter continues to preserve server identity, resolution, HLS/DASH format, request headers, and subtitles, and filters stream candidates to HTTP(S) URLs before offering them to BetterPlayer.
Added a focused provider-identity test and discovery diagnostics listing the actual runnable sources.
Android app identity
Launcher label: CineStream Pro N (CineStream Pro N Dev for the dev flavor).
Android namespace / application ID: com.m5ham3ds.cinestreampron.
Kotlin production and test package declarations, source folders, manifest package attributes, and R8 keep rules were migrated to the new ID.
Native notification/download labels, About/update/TV/home branding, ad copy, image-download folders, and visible translations were rebranded. Internal Dart import namespace (package:flixquest/...), method-channel names, request User-Agent compatibility strings, backend URLs, and existing deep-link hosts were left unchanged to avoid breaking inherited integrations. The Dart package namespace is not the Android installable package ID.
Because the application ID changed, Android treats this as a different app identity. Existing installs using the old package must be uninstalled (or installed alongside it) and their private app data is not migrated automatically. Existing flix.quest verified App Links will also need the new package ID added to the domain's assetlinks.json before Android can verify them for the new app. Firebase registration must use the new ID when Firebase is enabled in a later phase.
TMDB configuration
The user-provided TMDB v3 public API key is present in .env.example, and the existing workflow continues to copy .env.example to .env before building.
The value is compiled into the client APK and is extractable; it is not a private secret. Restrict it in TMDB's settings where possible and rotate it if it is ever abused. No GitHub Secret was added.
APK size and ABI
The build remains a single Debug APK for android-arm64; --split-per-abi is not used.
Gradle abiFilters is aligned to arm64-v8a as a second guard.
CI now audits the resulting APK, fails if another ABI directory is included, reports compressed and uncompressed payload by category, lists the 25 largest entries, verifies the final application ID where aapt is available, and uploads apk-size-report.md with the APK.
The previous observed 79.7 MB output was already produced by an ARM64-only Debug build. This phase does not claim a reduced size before the next CI report identifies the actual largest contributors. No plugin/library was removed just to lower the number.
Verification status
Source edits and Android package/path references were checked statically in the working tree. All Android XML files parse, translation JSON parses, and the GitHub Actions YAML plus embedded APK-audit Python script pass syntax checks.
Translation JSON files are parsed/validated after rebranding.
Workflow YAML and the APK-audit script are checked for syntax/structure in this workspace.
Flutter/Dart SDKs are not installed in this editing environment, so dart format, flutter analyze, flutter test, and a new APK build cannot be executed here. The next GitHub Actions run remains the authoritative compile/build check, followed by a real device test of automatic provider failover.
Device test checklist for the next APK
Confirm the launcher label is CineStream Pro N and package ID is com.m5ham3ds.cinestreampron.
Open Source repositories and add/sync the OpenStream repository.
Open a movie or episode: the loading progress should count individual runnable providers, not just Unified Sources and VixSrc.
In the player, open Select Video Provider and confirm source names appear individually. Unsupported manifest types should not appear as functioning providers.
Start playback. If a selected source fails, verify the player attempts the next stream/provider automatically and logs [PlaybackRecovery][NEXT_PROVIDER] before it shows the final error.
Review the CI artifact apk-size-report.md before considering any dependency removal.
