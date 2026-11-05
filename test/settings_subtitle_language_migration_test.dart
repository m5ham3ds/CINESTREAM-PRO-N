import 'package:flixquest/constants/app_constants.dart';
import 'package:flixquest/preferences/setting_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    sharedPrefsSingleton = await SharedPreferences.getInstance();
  });

  test('uses Arabic as the new default and persists the migration', () async {
    final preferences = SettingsPreferences();
    expect(await preferences.getSubLanguage(), 'ar');
    expect(
      sharedPrefsSingleton.getString(SettingsPreferences.DEFAULT_SUBTITLE_V3),
      'ar',
    );
  });

  test('migrates the previous inherited English default to Arabic', () async {
    await sharedPrefsSingleton.setString(
      SettingsPreferences.DEFAULT_SUBTITLE,
      'en',
    );
    final preferences = SettingsPreferences();
    expect(await preferences.getSubLanguage(), 'ar');
    expect(
      sharedPrefsSingleton.getString(SettingsPreferences.DEFAULT_SUBTITLE),
      'ar',
    );
  });

  test('preserves a previously selected non-English subtitle language', () async {
    await sharedPrefsSingleton.setString(
      SettingsPreferences.DEFAULT_SUBTITLE,
      'fr',
    );
    final preferences = SettingsPreferences();
    expect(await preferences.getSubLanguage(), 'fr');
  });

  test('preserves the explicit Any language choice', () async {
    final preferences = SettingsPreferences();
    await preferences.setDefaultSubtitle('');
    expect(await preferences.getSubLanguage(), '');
  });

  test('does not overwrite a language already saved in version three', () async {
    await sharedPrefsSingleton.setString(
      SettingsPreferences.DEFAULT_SUBTITLE_V3,
      'it',
    );
    final preferences = SettingsPreferences();
    expect(await preferences.getSubLanguage(), 'it');
  });
}
