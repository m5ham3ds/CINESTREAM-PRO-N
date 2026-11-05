import 'app_runtime.dart';

/// Explicit feature sets for isolated tests; app runtime follows service mode.
class MigrationFlags {
  MigrationFlags.parse(String value)
      : _features = value.split(',').map((item) => item.trim()).toSet();

  /// Local mode is guest-only and keeps cloud config, sync, ads, notifications,
  /// and telemetry disabled. Account APIs can be re-enabled in a later backend
  /// integration phase without changing the local-development preset.
  factory MigrationFlags.fromRuntime({
    bool firebaseEnabled = AppRuntime.firebaseEnabled,
    bool localDevelopment = AppRuntime.localDevelopment,
  }) {
    if (localDevelopment) return MigrationFlags.parse('auth');
    return MigrationFlags.parse(firebaseEnabled
        ? 'auth,config,ads,sync,notifications'
        : 'auth,ads,sync');
  }

  final Set<String> _features;
  bool get auth => _features.contains('auth');
  bool get config => _features.contains('config');
  bool get ads => _features.contains('ads');
  bool get sync => _features.contains('sync');
  bool get notifications => _features.contains('notifications');
  bool get telemetry => _features.contains('telemetry');
}
