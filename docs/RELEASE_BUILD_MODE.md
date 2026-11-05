# Release-first Android build mode

CINESTREAM-PRO-N now builds Flutter `Release` mode by default. Push and pull-request workflows use `--release`; a manual GitHub Actions run offers a `build_mode` selector with `release` and `debug`.

Choose `debug` only when a test or a diagnostic requires debug symbols, assertions, or debug behavior. Switching back to `release` requires no source changes. Both variants keep the same `prod` flavor, Android application ID, ARM64-only single-APK output, and local-mode Dart defines:

- `ENABLE_FIREBASE=false`
- `LOCAL_DEV_MODE=true`

## Signing behavior

If `android/key.properties` points to a complete private keystore, the Release variant uses it. Otherwise, Release falls back to the Android debug signing identity. GitHub Actions caches the CI debug keystore so Release and Debug artifacts from this workflow share a signing certificate and can be installed over one another. That CI key is for development/testing only and must not be used as a public production-distribution key. Keep any real private keystore and its passwords out of source control.

## Output

Both modes are copied to the same artifact name, `CINESTREAM-PRO-N-apk.apk`; the accompanying `apk-size-report.md` identifies whether the artifact was built in `RELEASE` or `DEBUG` mode.
