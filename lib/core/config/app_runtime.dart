/// Runtime switches for local development and the future Firebase rollout.
///
/// Firebase is opt-in and is always suppressed by the local-only preset. The
/// local preset is explicit so ordinary unit tests and backend-enabled
/// developer builds can still exercise their services.
class AppRuntime {
  AppRuntime._();

  static const bool localDevelopment =
      bool.fromEnvironment('LOCAL_DEV_MODE', defaultValue: false);

  static const bool firebaseEnabled =
      bool.fromEnvironment('ENABLE_FIREBASE', defaultValue: false) &&
          !localDevelopment;

  static const bool useLocalServices = localDevelopment;
}
