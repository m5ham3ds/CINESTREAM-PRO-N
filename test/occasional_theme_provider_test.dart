import 'package:flixquest/constants/app_constants.dart';
import 'package:flixquest/models/occasional_theme.dart';
import 'package:flixquest/provider/app_dependency_provider.dart';
import 'package:flixquest/singleton/sharedpreferences_singleton.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    dotenv.testLoad(
      fileInput: '''
        TMDB_API_KEY=test
        MIXPANEL_API_KEY=test
        FLIXQUEST_API_URL=https://example.com
      ''',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{});
    sharedPrefsSingleton = await SharedPreferencesSingleton.getInstance();
  });

  test('manual seasonal presets are available without overriding automatic Ambient mode', () {
    final catalog = OccasionalThemeCatalog.localDefaults(
      now: DateTime.utc(2026, 3, 20),
    );
    expect(
      catalog.resolve(
        selectedThemeId: 'automatic',
        now: DateTime.utc(2026, 3, 20),
      ),
      isNull,
    );
    expect(
      catalog.resolve(
        selectedThemeId: 'eid',
        now: DateTime.utc(2026, 3, 20),
      )?.id,
      'eid',
    );
    expect(
      catalog.resolve(
        selectedThemeId: 'autumn',
        now: DateTime.utc(2026, 3, 20),
      )?.id,
      'autumn',
    );
  });

  test('seasonal themes default on and can be persistently disabled', () async {
    final provider = AppDependencyProvider();
    await provider.getOccasionalTheme();
    expect(provider.occasionalThemeCatalog.enabled, isTrue);
    expect(provider.occasionalThemeCatalog.allowUserSelection, isTrue);
    expect(provider.occasionalThemeCatalog.allowUserEffectsToggle, isTrue);
    expect(provider.availableOccasionalThemes, isNotEmpty);
    provider.selectOccasionalTheme('eid');
    expect(provider.activeOccasionalTheme?.id, 'eid');
    expect(provider.shouldShowOccasionalEffects, isTrue);
    provider.selectOccasionalTheme('automatic');
    provider.occasionalThemeCatalog = OccasionalThemeCatalog.fromJsonString('''
      {
        "schema_version": 2,
        "enabled": true,
        "themes": [
          {"id": "christmas", "enabled": true}
        ]
      }
    ''');

    expect(provider.occasionalThemeEnabled, isTrue);
    expect(provider.activeOccasionalTheme?.id, 'christmas');

    provider.occasionalThemeEnabled = false;
    expect(provider.activeOccasionalTheme, isNull);
    await Future<void>.delayed(Duration.zero);

    final restoredProvider = AppDependencyProvider();
    await restoredProvider.getOccasionalTheme();
    expect(restoredProvider.occasionalThemeEnabled, isFalse);
    expect(restoredProvider.activeOccasionalTheme, isNull);

    provider.dispose();
    restoredProvider.dispose();
  });


  test('disabled bootstrap catalog falls back to built-in seasonal settings', () async {
    final provider = AppDependencyProvider();
    await provider.getOccasionalTheme();
    provider.applyOccasionalThemeCatalog(
      const OccasionalThemeCatalog.disabled(),
    );

    expect(provider.occasionalThemeCatalog.enabled, isTrue);
    expect(provider.availableOccasionalThemes, isNotEmpty);
    expect(provider.occasionalThemeCatalog.allowUserSelection, isTrue);
    expect(provider.occasionalThemeCatalog.allowUserEffectsToggle, isTrue);

    provider.dispose();
  });

  test('invalid remote JSON preserves the last hardcoded occasion', () {
    final provider = AppDependencyProvider();
    provider.occasionalThemeCatalog = OccasionalThemeCatalog.fromJsonString('''
      {
        "schema_version": 2,
        "enabled": true,
        "themes": [
          {"id": "halloween", "enabled": true}
        ]
      }
    ''');

    expect(provider.activeOccasionalTheme?.id, 'halloween');
    expect(provider.applyRemoteOccasionalTheme('not-json'), isFalse);
    expect(provider.activeOccasionalTheme?.id, 'halloween');
    expect(
      provider.applyRemoteOccasionalTheme('''
        {
          "schema_version": 2,
          "enabled": true,
          "themes": [
            {"id": "unknown_event", "enabled": true, "colors": ["#123456"]}
          ]
        }
      '''),
      isFalse,
    );
    expect(provider.activeOccasionalTheme?.id, 'halloween');

    expect(
      provider.applyRemoteOccasionalTheme('''
        {
          "schema_version": 2,
          "enabled": true,
          "themes": [
            {
              "id": "unknown_event",
              "enabled": true,
              "colors": ["#123456", "#FEDCBA"]
            }
          ]
        }
      '''),
      isTrue,
    );
    expect(provider.activeOccasionalTheme?.id, 'unknown_event');

    provider.dispose();
  });
}
