import 'package:flixquest/core/config/migration_flags.dart';
import 'package:flixquest/core/config/app_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only explicitly selected features cut over', () {
    final flags = MigrationFlags.parse(' auth,config, auth,typo ');
    expect(flags.auth, isTrue);
    expect(flags.config, isTrue);
    expect(flags.ads, isFalse);
    expect(flags.sync, isFalse);
    expect(MigrationFlags.parse('').auth, isFalse);
  });
  test('Firebase and local-only mode are explicit build options', () {
    expect(AppRuntime.firebaseEnabled, isFalse);
    expect(AppRuntime.localDevelopment, isFalse);
    expect(AppRuntime.useLocalServices, isFalse);
  });

  test('default non-Firebase build keeps Laravel service flags available', () {
    final flags = MigrationFlags.fromRuntime();
    expect(flags.auth, isTrue);
    expect(flags.config, isFalse);
    expect(flags.ads, isTrue);
    expect(flags.sync, isTrue);
    expect(flags.notifications, isFalse);
  });

  test('local runtime overrides a Firebase opt-in', () {
    final flags = MigrationFlags.fromRuntime(
        firebaseEnabled: true, localDevelopment: true);
    expect(flags.auth, isTrue);
    expect(flags.config, isFalse);
    expect(flags.ads, isFalse);
    expect(flags.sync, isFalse);
    expect(flags.notifications, isFalse);
  });

  test('local runtime does not start cloud-only services', () {
    final flags = MigrationFlags.fromRuntime(
        firebaseEnabled: false, localDevelopment: true);
    expect(flags.auth, isTrue);
    expect(flags.config, isFalse);
    expect(flags.ads, isFalse);
    expect(flags.sync, isFalse);
    expect(flags.notifications, isFalse);
    expect(flags.telemetry, isFalse);
  });

  test('non-local Laravel mode retains sync and ads without Firebase', () {
    final flags = MigrationFlags.fromRuntime(
        firebaseEnabled: false, localDevelopment: false);
    expect(flags.auth, isTrue);
    expect(flags.config, isFalse);
    expect(flags.ads, isTrue);
    expect(flags.sync, isTrue);
    expect(flags.notifications, isFalse);
  });

  test('Firebase services remain available as an explicit future opt-in', () {
    final flags = MigrationFlags.fromRuntime(
        firebaseEnabled: true, localDevelopment: false);
    expect(flags.auth, isTrue);
    expect(flags.config, isTrue);
    expect(flags.ads, isTrue);
    expect(flags.sync, isTrue);
    expect(flags.notifications, isTrue);
  });
}
