# Local Development Mode

The GitHub Actions APK build explicitly enables a local-development compatibility mode and is deliberately independent of a Firebase project. A normal local `flutter run` does not silently enable this preset; pass `--dart-define=LOCAL_DEV_MODE=true` to run the same guest-only mode. It can be built and launched without `android/app/google-services.json`, Firebase API credentials, FCM, Crashlytics, or Remote Config. This is not a Firebase Emulator Suite connection: the active app architecture uses local device storage for guest browsing and Laravel for account APIs, and does not currently depend on Firestore.

## What is active locally

- Flutter app startup and local preferences/database storage.
- Guest browsing state and local watch history/bookmarks/download metadata. A local guest is persisted on-device and does not call `auth/guest`. Previously saved API tokens are ignored at startup but preserved securely for a future backend-enabled build.
- TMDB/source requests where the public API configuration is supplied. `TMDB_API_KEY` is blank in the included `.env.example`; metadata browsing therefore needs a TMDB API key in the local `.env`, or the optional GitHub Actions Secret `TMDB_API_KEY` for CI packaging. The key is embedded in the client APK and should be restricted as a public client key.
- Laravel account APIs remain configured by `LARAVEL_API_URL`; local guest browsing does not require a reachable Laravel server. Email/password account operations cannot complete until the Laravel backend is available.

## What is intentionally off

- Firebase initialization and legacy Firebase-session migration.
- Firebase Remote Config and Firebase-driven Laravel endpoint changes.
- Firebase Cloud Messaging, OneSignal notification registration, and notification permissions. Google sign-in buttons are hidden until OAuth/Firebase settings are supplied.
- Crashlytics reporting. Player errors remain visible in local logs.
- Mixpanel initialization and outbound analytics events.
- Ad-block network probes, Adsterra popunders/interstitials, hosted/network banners, VAST pre-rolls, and the old scraper-backed branded-intro request.
- Cloud sync, Plus/billing catalog requests, and server-driven ad configuration in this local preset.

These switches prevent calls to Firebase SDK singletons before a Firebase app exists. Ad gates and ad-backed intro requests are also bypassed so they cannot block a local playback test. Local guest state is stored with the existing on-device preferences and local database layer. The app currently uses Laravel for account and synchronization APIs; a Firebase Emulator is not part of this stage because the active client does not use Firestore and Remote Config/FCM/Crashlytics do not provide a complete local emulator path.

## Build defaults

The GitHub Actions workflow now builds **Release mode by default** with these local-mode flags and the ARM64-only single-APK target:

```bash
flutter build apk --release --flavor prod --target lib/main.dart \
  --target-platform android-arm64 \
  -Pdisable-abi-filtering=true \
  --dart-define=ENABLE_FIREBASE=false \
  --dart-define=LOCAL_DEV_MODE=true
```

To diagnose a Release-only problem, start a manual GitHub Actions run and select `debug` in the `build_mode` input. Push and pull-request builds remain Release by default. The workflow copies either variant to the same artifact name, `CINESTREAM-PRO-N-apk.apk`, and the size report records the selected mode.

When no private `android/key.properties` keystore is supplied, the Release build uses the cached CI development signing identity. This makes Release and Debug artifacts from the workflow installable over each other for testing. It is not a production-distribution signing key.

## Future real Firebase integration

Only after creating the Firebase Android app with the final application ID should the team add its matching `google-services.json`, enable the Google Services/Crashlytics Gradle plugins with `-PenableFirebaseGradlePlugins=true`, and build with `--dart-define=ENABLE_FIREBASE=true --dart-define=LOCAL_DEV_MODE=false`. Then re-enable the intended feature flags and validate Auth, Remote Config, FCM, and Crashlytics independently. The Firebase-backed feature set remains opt-in; do not use the old FlixQuest Firebase project file. Never commit service-account credentials or private server keys.
