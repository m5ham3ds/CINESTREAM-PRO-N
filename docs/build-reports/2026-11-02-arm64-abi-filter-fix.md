# CINESTREAM-PRO-N — ARM64-only APK build correction

## CI failure observed

The APK was built, but the post-build ABI audit correctly rejected it because the archive contained:

- `arm64-v8a`
- `armeabi-v7a`
- `x86_64`

The earlier Gradle configuration only appended `arm64-v8a`. Flutter 3.35+ automatically supplies a default ABI filter set, so appending ARM64 did not remove the other entries.

## Correction

In `android/app/build.gradle`, `defaultConfig.ndk` now explicitly clears the inherited filters and adds only `arm64-v8a`:

```groovy
ndk {
    abiFilters.clear()
    abiFilters.add('arm64-v8a')
}
```

The workflow retains `--target-platform android-arm64`, Debug, `prod`, local-development defines, one APK, and the existing artifact name. It does not use `--split-per-abi`. The strict APK audit remains enabled so a future regression fails visibly rather than silently shipping extra architectures.

## Scope and verification

No runtime dependency, source engine, native library, or player code was removed or changed. The APK was not built in this editing environment because Flutter/Dart are unavailable here. The next GitHub Actions run must confirm that the archive contains exactly `lib/arm64-v8a/` and no other ABI folder.
