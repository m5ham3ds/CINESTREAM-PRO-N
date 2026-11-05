# GitHub Actions — CINESTREAM-PRO-N Local Android APK

The workflow is located at `.github/workflows/android-ci.yml`.

## What it does

- Runs on push, pull requests, and manual `workflow_dispatch`.
- Uses Java 17 and Flutter 3.35.7.
- Uses `android-actions/setup-android@v4` to install Android command-line tools, accept SDK licenses, add `sdkmanager` to `PATH`, and install Android SDK 36, Build Tools 36.0.0, and NDK 28.2.13676358.
- Creates `.env` from `.env.example` when `.env` is absent.
- Optionally injects `TMDB_API_KEY` from a repository Actions Secret. Without it, the APK still builds, but TMDB metadata requests may not work until a key is supplied.
- Resolves Flutter packages and builds the `prod` flavor as a single ARM64-only **Release APK by default** in local-development mode. Manual runs expose a `build_mode` choice (`release` or `debug`); choose Debug only when diagnosing a Release-only issue. Push and pull-request builds always default to Release.
- The workflow keeps a CI-only Android debug keystore in Actions cache. Both build modes use the same signing identity when no private `android/key.properties` keystore is supplied, so a Debug APK can replace a Release APK and successive CI artifacts remain installable as updates. This cached key is for development/testing only, not for public production distribution. A private release keystore in `android/key.properties` takes precedence when configured.
- The workflow passes `--target-platform android-arm64` and `-Pdisable-abi-filtering=true`; the `prod` flavor explicitly selects `arm64-v8a`, and JNI packaging excludes every other supported Android ABI as a final guard.
- Audits the APK ZIP entries and fails if any ABI other than `arm64-v8a` is present. The audit writes `apk-size-report.md` before failing, including per-ABI native-library sizes and the largest `.so` files; CI uploads diagnostics even when the audit fails.
- Renames the resulting file to `CINESTREAM-PRO-N-apk.apk` and uploads it with the size report as the `CINESTREAM-PRO-N-apk` artifact for 14 days.

## Local development mode (Firebase deferred)

The CI build passes `ENABLE_FIREBASE=false` and `LOCAL_DEV_MODE=true`. This is a Firebase-free local compatibility mode, not a Firebase Emulator Suite connection. It supports local guest browsing and local device storage without requiring `google-services.json`, Firebase secrets, a Firebase project, Laravel account endpoints, remote config, push registration, Crashlytics, server sync, or server-driven ads. Previously saved Laravel tokens are ignored during local startup but preserved in secure storage for a future backend-enabled build. Mixpanel initialization is also skipped in this mode.

This project does not use Firestore for its current account/library architecture. Laravel is the account and sync backend; TMDB and stream providers are separate external services. To load TMDB metadata in CI, add a repository Actions Secret named `TMDB_API_KEY`; for a local build, put the key in `.env`. The key is bundled into the client APK, so treat it as a public client key and restrict it in TMDB settings. If it is absent, the APK still builds, but metadata requests may fail. Email/password accounts, cross-device sync, billing, and notifications are intentionally unavailable until their real backends are configured.

No Firebase Emulator is configured because it would not emulate the app's current Laravel auth/sync, TMDB, Remote Config, FCM, or Crashlytics behavior as a complete local stack.

## Future real Firebase integration

When the project is ready to connect its own Firebase Android app, provide a `google-services.json` matching the app's `applicationId`, enable the Google Services/Crashlytics Gradle plugins with `-PenableFirebaseGradlePlugins=true`, then build with `--dart-define=ENABLE_FIREBASE=true --dart-define=LOCAL_DEV_MODE=false`. Test Auth migration, Remote Config, FCM, and Crashlytics independently. Do not use the old FlixQuest Firebase project file. Never commit service-account credentials or private server keys.

## Start a build

1. Commit `.github/workflows/android-ci.yml` and the project changes to the `CINESTREAM-PRO-N` repository.
2. Open **Actions**.
3. Select **CINESTREAM-PRO-N Local Android APK Build**.
4. Choose **Run workflow**, or push a commit to trigger it automatically.
5. Download `CINESTREAM-PRO-N-apk` from the completed run's Artifacts.

The default artifact is a Flutter Release-mode APK with R8/resource shrinking enabled. When no private release keystore is provided, it is signed with the cached CI development key so it can be installed for testing; it is not a production-distribution signature. To build Debug, choose `debug` in the manual workflow's `build_mode` selector. Both modes keep the same application ID and CI signing identity.
