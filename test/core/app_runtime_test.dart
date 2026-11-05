import 'package:flixquest/core/config/app_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Firebase and local-only mode require explicit build flags', () {
    expect(AppRuntime.firebaseEnabled, isFalse);
    expect(AppRuntime.localDevelopment, isFalse);
    expect(AppRuntime.useLocalServices, isFalse);
  });
}
