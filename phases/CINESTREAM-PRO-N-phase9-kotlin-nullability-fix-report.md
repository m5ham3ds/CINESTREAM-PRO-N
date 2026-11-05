
Phase 9 — OpenStream Web Embed Kotlin nullability build fix
Project: CINESTREAM-PRO-N
Build mode: Release remains the default; Debug remains available through manual workflow dispatch.
Scope: One Kotlin compile failure in OpenStreamWebEmbedBridge.kt.

Failure reported by GitHub Actions
The compileProdReleaseKotlin task failed at OpenStreamWebEmbedBridge.kt:54:

Argument type mismatch: actual type is 'kotlin.String?', but 'kotlin.String' was expected.
The Android Uri.host property is nullable. The earlier URL validation checked isNullOrBlank(), but that check does not change Kotlin's static type of the property for subsequent expressions. The fallback ?: uri.host therefore left sourceName typed as nullable, while resolve() requires a non-null String.

Change made
After the existing HTTP(S), host, and user-info validation, the bridge now normalizes the already-validated host once:

val host = uri.host.orEmpty()
It then uses that non-null value for the default Referer and source name. An optional source name is trimmed, rejected if blank, and limited to 80 characters before falling back to the normalized host.

This avoids a force unwrap (!!) and does not change WebView navigation, media capture, metadata parsing, cookies, headers, or playback behavior.

Scope deliberately unchanged
No provider implementations or source ordering were changed.
No Flutter/Dart files were changed.
No dependency versions were changed.
Release remains the default build mode; Debug remains a manual option.
ARM64-only packaging and single-APK output remain unchanged.
BetterPlayer, QuickJS, downloads, and media extraction code were not modified.
Validation
The affected Kotlin expression and its call into a function requiring String were compiled with the installed Kotlin compiler in an isolated type-check.
Source inspection confirms sourceName now falls back to the non-null host value.
The project archive was checked for ZIP integrity.
A full Android/Flutter Release build was not run in this environment; GitHub Actions must confirm compileProdReleaseKotlin and assembleProdRelease.
Expected result
The reported nullable-`String` compiler error at line 54 should be resolved. The AndroidX/old support-library Jetifier messages in the supplied log are warnings and were not the cause of this failure.

