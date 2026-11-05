# PHASE 26 — Player controls configuration syntax fix

## Build failure addressed

The Phase 25 build failed while compiling `lib/screens/common/player.dart`.
The first diagnostic pointed to the opening parenthesis of
`BetterPlayerControlsConfiguration(` at line 440 and reported that Dart could
not find its matching `)`. The later diagnostics around the declaration of
`BetterPlayerConfiguration` and the controller construction were parser
cascade errors caused by the same missing delimiter.

## Root cause

The `overflowMenuCustomItems` argument ended with `: const [],` but the
`BetterPlayerControlsConfiguration(...)` invocation was not closed before the
next local declaration:

```dart
BetterPlayerConfiguration betterPlayerConfiguration =
```

As a result, Dart parsed the following declaration as if it were still inside
the controls-configuration call. This also explains the misleading
"Too many positional arguments" diagnostic from the named-parameter
constructor.

## Exact correction

Added the missing closing delimiter immediately after the
`overflowMenuCustomItems` argument:

```dart
            : const [],
    );

    BetterPlayerConfiguration betterPlayerConfiguration =
```

No other Dart code was changed.

## Scope and preservation checks

- Only `lib/screens/common/player.dart` changed relative to the Phase 25
  project, and the sole code difference is the missing `);` above.
- The handheld quick-action order, icon-only/space-adaptive rendering, HD
  action callback, unified all-provider quality catalog, subtitle bridge,
  provider switcher, and three-item wide More configuration are unchanged.
- TV-specific menu entries and TV controls are unchanged.
- Provider engines, source extraction, movie/TV loaders, playback recovery,
  caching, and subtitle modules are unchanged.
- Earlier phase reports were not modified or removed.

## Verification performed

- Confirmed the controls configuration closes before the
  `BetterPlayerConfiguration` declaration.
- Ran a Dart-aware delimiter scan across the complete `player.dart`; all
  parentheses, brackets, and braces are balanced.
- Compared the fixed project with the Phase 25 archive; the only source-code
  difference is the added closing `);`.
- Rebuilt and inspected the ZIP archive and its required top-level project
  directory.

## Verification limitation

Flutter/Dart SDK is not installed in this editing environment, so
`flutter analyze`, `dart format`, and `flutter build apk --release` could not
be executed here. The reported syntax defect is corrected, but a successful
APK build has not been independently confirmed in this environment.
