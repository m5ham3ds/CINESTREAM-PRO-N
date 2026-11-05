
Release-first build mode change
Date: 2026-11-02

Decision
The Android CI workflow now builds Flutter Release mode by default. A manual GitHub Actions run offers build_mode choices release and debug, with release as the default. Push and pull-request events always use Release.

Changes
.github/workflows/android-ci.yml
Added the manual build_mode selector.
Added one mode switch that selects the matching Flutter flag and output path.
Preserved prod, lib/main.dart, android-arm64, -Pdisable-abi-filtering=true, and both local-mode Dart defines.
Preserved the single artifact name CINESTREAM-PRO-N-apk.apk and the APK/size-report upload step.
Added a repository-scoped Actions cache for the CI development signing key, so Debug and Release builds from CI share an install/update signature when no private release key is configured.
Added an explicit key-generation step for a cache miss.
Added the selected build mode to apk-size-report.md.
android/app/build.gradle
Release continues to use minifyEnabled true and shrinkResources true.
A complete private android/key.properties release keystore takes precedence.
When no complete private keystore is present, Release falls back to the Android debug signing identity, allowing the CI Release and Debug variants to be installed over one another.
Existing ARM64-only filters and native packaging exclusions are preserved.
docs/GITHUB_ACTIONS_BUILD.md, docs/LOCAL_DEVELOPMENT_MODE.md, and docs/RELEASE_BUILD_MODE.md
Updated build instructions and documented the signing behavior and Debug fallback.
Validation performed in this workspace
GitHub Actions workflow YAML parsed successfully.
Confirmed that push/PR defaults resolve to Release and manual dispatch exposes release and debug.
Confirmed both Flutter output paths are used and the output artifact keeps the same filename.
Confirmed ARM64-only target and no --split-per-abi were introduced.
Confirmed the Release build retains R8/minification and resource shrinking.
Generated and inspected a temporary keystore with the same keytool parameters used by CI.
Confirmed artifact upload remains under if: always() and includes the size report.
Not run
Flutter, Dart, and the Android build toolchain are not available in this editing environment. Therefore, no real flutter build apk --release, Gradle Release variant build, APK installation, or runtime test was performed here. The next GitHub Actions run is the authoritative Release build validation.

Signing warning
The cached CI debug keystore is solely for development/testing. Do not distribute it as a production signing identity. Before public release, use a private keystore and keep its credentials out of the repository. When a private release key is configured, Release uses that key instead of the debug fallback.

