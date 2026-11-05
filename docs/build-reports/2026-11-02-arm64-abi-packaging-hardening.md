# ARM64-only APK packaging hardening — 2026-11-02

## Why the previous fix was insufficient

The prior correction only configured `defaultConfig.ndk.abiFilters`. The subsequent CI APK still contained `arm64-v8a`, `armeabi-v7a`, and `x86_64`, so the final artifact—not the intended Gradle setting—remains the source of truth. The exact originating AAR/library cannot be identified without the APK produced by the failed run.

## Changes made

- Retained the `android-arm64` Flutter target and the single-APK build.
- Added `-Pdisable-abi-filtering=true` to the Flutter build command.
- Set the `prod` flavor's NDK ABI filter explicitly to `arm64-v8a`.
- Kept the `defaultConfig` ARM64 filter.
- Added Android JNI packaging excludes for `armeabi-v7a`, `armeabi`, `x86`, `x86_64`, `mips`, `mips64`, and `riscv64`, without removing the ARM64 native libraries or plugins.
- Changed the ABI audit to write a report before it fails. The report lists ABI directories, `.so` counts, per-ABI compressed/uncompressed size, and the largest native libraries.
- Made the artifact upload step run even if the strict audit fails, so the APK and diagnostic report can be inspected instead of losing the evidence.

## Preserved

- Flutter 3.35.7, Java 17, Gradle 8.7, AGP 8.6.0, NDK 28.2.13676358.
- Debug / `prod` / `lib/main.dart`.
- `ENABLE_FIREBASE=false` and `LOCAL_DEV_MODE=true`.
- One APK named `CINESTREAM-PRO-N-apk.apk`; no `--split-per-abi`.
- Existing playback, QuickJS, Media3, download, and source-engine dependencies. No libraries were deleted.

## Verification status

- Gradle/workflow source edits and YAML structure were checked statically.
- The ZIP archive is valid and includes the updated Android Gradle file, workflow, and report.
- Flutter/Gradle Android build was not run in this editing environment. A real GitHub Actions build is still required to confirm the final APK contains only `lib/arm64-v8a/`.
