import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'source_manifest.dart';
import 'source_repository_client.dart';

class SourceRepositorySyncResult {
  const SourceRepositorySyncResult({
    required this.repositories,
    required this.sources,
    required this.errors,
    this.catalog = const <SourceManifest>[],
  });

  final List<SourceRepositoryManifest> repositories;

  /// Installed and enabled sources that are eligible for resolution.
  final List<SourceManifest> sources;

  /// Every source discovered in the repositories, including uninstalled ones.
  final List<SourceManifest> catalog;
  final Map<String, String> errors;
}

/// Persists user-added repository URLs and refreshes their manifests.
///
/// Repository entries are metadata only: an engine is executed only when its
/// type has a registered implementation and its manifest passes validation.
class SourceRepositoryManager {
  SourceRepositoryManager({
    SourceRepositoryClient? client,
    SharedPreferences? preferences,
  })  : _client = client ?? SourceRepositoryClient(),
        _preferences = preferences;

  static const String defaultOpenStreamRepository =
      'https://raw.githubusercontent.com/Ivorisnoob/OpenStream/main/extensions/index.json';
  static const String _defaultRepositorySeededKey =
      'unified_source_default_repository_seeded_v1';
  static const String _repositoriesKey = 'unified_source_repository_urls_v1';
  static const String _installedSourcesKey = 'unified_installed_source_keys_v1';
  static const String _disabledDefaultsKey = 'unified_disabled_default_source_keys_v1';
  static const Duration catalogCacheTtl = Duration(minutes: 5);

  SourceRepositorySyncResult? _catalogCache;
  DateTime? _catalogCachedAt;
  Future<SourceRepositorySyncResult>? _catalogRefresh;

  final SourceRepositoryClient _client;
  final SharedPreferences? _preferences;
  SharedPreferences? _resolvedPreferences;

  Future<SharedPreferences> get _prefs async {
    if (_preferences != null) return _preferences;
    return _resolvedPreferences ??= await SharedPreferences.getInstance();
  }

  Future<List<String>> repositoryUrls() async {
    final preferences = await _prefs;
    final raw = preferences.getStringList(_repositoriesKey) ?? const <String>[];
    return raw
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  Future<void> addRepository(String url) async {
    final normalized = SourceRepositoryClient.normalizeRepositoryUrl(url);
    final current = await repositoryUrls();
    if (current.contains(normalized)) return;
    final preferences = await _prefs;
    await preferences.setStringList(
      _repositoriesKey,
      <String>[...current, normalized],
    );
    _invalidateCatalogCache();
  }

  Future<void> removeRepository(String url) async {
    final normalized = SourceRepositoryClient.normalizeRepositoryUrl(url);
    final current = List<String>.of(await repositoryUrls());
    current.remove(normalized);
    final preferences = await _prefs;
    await preferences.setStringList(_repositoriesKey, current);

    // Remove orphaned installation preferences tied to this repository. The
    // source catalog itself is still fetched on the next sync, so re-adding
    // the repository starts with a clean install state.
    final sourcePrefix = '$normalized::';
    final installed = await installedSourceKeys();
    installed.removeWhere((key) => key.startsWith(sourcePrefix));
    await preferences.setStringList(
      _installedSourcesKey,
      installed.toList(growable: false),
    );
    final disabledDefaults = await disabledDefaultSourceKeys();
    disabledDefaults.removeWhere((key) => key.startsWith(sourcePrefix));
    await preferences.setStringList(
      _disabledDefaultsKey,
      disabledDefaults.toList(growable: false),
    );
    _invalidateCatalogCache();
  }

  Future<Set<String>> installedSourceKeys() async {
    final preferences = await _prefs;
    return (preferences.getStringList(_installedSourcesKey) ?? const <String>[])
        .toSet();
  }

  Future<void> installSource(SourceManifest source) async {
    final preferences = await _prefs;
    final installed = await installedSourceKeys();
    installed.add(source.stableKey);
    await preferences.setStringList(
      _installedSourcesKey,
      installed.toList(growable: false),
    );
    final disabledDefaults = await disabledDefaultSourceKeys();
    disabledDefaults.remove(source.stableKey);
    await preferences.setStringList(
      _disabledDefaultsKey,
      disabledDefaults.toList(growable: false),
    );
  }

  Future<void> uninstallSource(SourceManifest source) async {
    final preferences = await _prefs;
    final installed = await installedSourceKeys();
    installed.remove(source.stableKey);
    await preferences.setStringList(
      _installedSourcesKey,
      installed.toList(growable: false),
    );
    if (source.installedByDefault) {
      final disabledDefaults = await disabledDefaultSourceKeys();
      disabledDefaults.add(source.stableKey);
      await preferences.setStringList(
        _disabledDefaultsKey,
        disabledDefaults.toList(growable: false),
      );
    }
  }

  Future<Set<String>> disabledDefaultSourceKeys() async {
    final preferences = await _prefs;
    return (preferences.getStringList(_disabledDefaultsKey) ?? const <String>[])
        .toSet();
  }

  Future<void> _seedDefaultRepositoryOnce() async {
    final preferences = await _prefs;
    if (preferences.getBool(_defaultRepositorySeededKey) == true) return;
    final current = await repositoryUrls();
    if (!current.contains(defaultOpenStreamRepository)) {
      await preferences.setStringList(
        _repositoriesKey,
        <String>[...current, defaultOpenStreamRepository],
      );
    }
    await preferences.setBool(_defaultRepositorySeededKey, true);
  }

  Future<SourceRepositorySyncResult> sync({bool forceRefresh = false}) async {
    await _seedDefaultRepositoryOnce();
    var catalogSnapshot = _catalogCache;
    final cachedAt = _catalogCachedAt;
    final isFresh = catalogSnapshot != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < catalogCacheTtl;

    if (forceRefresh || !isFresh) {
      final pending = _catalogRefresh;
      if (pending != null && !forceRefresh) {
        catalogSnapshot = await pending;
      } else {
        if (pending != null && forceRefresh) {
          // Do not launch two full repository refreshes at the same time.
          // Wait for the in-flight one, then perform the requested refresh.
          try {
            catalogSnapshot = await pending;
          } catch (_) {
            // The explicit refresh below gets its own attempt.
          }
        }
        final refresh = _fetchCatalog();
        _catalogRefresh = refresh;
        try {
          final refreshed = await refresh;
          final previous = catalogSnapshot;
          catalogSnapshot = refreshed.catalog.isEmpty &&
                  refreshed.errors.isNotEmpty &&
                  previous?.catalog.isNotEmpty == true
              ? SourceRepositorySyncResult(
                  repositories: previous!.repositories,
                  sources: const <SourceManifest>[],
                  catalog: previous.catalog,
                  errors: refreshed.errors,
                )
              : refreshed;
          _catalogCache = catalogSnapshot;
          _catalogCachedAt = DateTime.now();
        } catch (_) {
          // Retain the last known catalogue if a refresh fails. The caller
          // still receives the previous snapshot, preserving offline playback.
          if (catalogSnapshot == null) rethrow;
        } finally {
          if (identical(_catalogRefresh, refresh)) _catalogRefresh = null;
        }
      }
    }

    final base = catalogSnapshot;
    if (base == null) {
      throw StateError('Source catalogue is unavailable.');
    }
    final installed = await installedSourceKeys();
    final disabledDefaults = await disabledDefaultSourceKeys();
    final activeSources = base.catalog.where((source) {
      if (!source.enabled || source.status == 0) return false;
      final isInstalled = installed.contains(source.stableKey) ||
          (source.installedByDefault &&
              !disabledDefaults.contains(source.stableKey));
      return isInstalled;
    }).toList(growable: false);

    return SourceRepositorySyncResult(
      repositories: base.repositories,
      sources: activeSources,
      catalog: base.catalog,
      errors: base.errors,
    );
  }

  Future<SourceRepositorySyncResult> _fetchCatalog() async {
    final urls = await repositoryUrls();
    final repositories = <SourceRepositoryManifest>[];
    final catalog = <SourceManifest>[];
    final errors = <String, String>{};
    final seenSources = <String>{};

    for (final url in urls) {
      try {
        final repository = await _client.fetchRepository(url);
        repositories.add(repository);
        for (final source in repository.extensions) {
          if (seenSources.add(source.stableKey)) catalog.add(source);
        }
      } catch (error) {
        errors[url] = error.toString();
      }
    }

    return SourceRepositorySyncResult(
      repositories: repositories,
      sources: const <SourceManifest>[],
      catalog: catalog,
      errors: errors,
    );
  }

  void _invalidateCatalogCache() {
    _catalogCache = null;
    _catalogCachedAt = null;
  }

  /// Export/import helpers make repository and install configuration portable.
  Future<String> exportConfiguration() async => jsonEncode(
        <String, dynamic>{
          'schemaVersion': 2,
          'repositories': await repositoryUrls(),
          'installedSources': (await installedSourceKeys()).toList(),
          'disabledDefaultSources':
              (await disabledDefaultSourceKeys()).toList(),
        },
      );

  Future<void> importConfiguration(String raw) async {
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['repositories'] is! List) {
      throw const FormatException('Invalid source repository configuration.');
    }
    final normalized = <String>{};
    for (final value in decoded['repositories'] as List) {
      if (value is! String) continue;
      normalized.add(SourceRepositoryClient.normalizeRepositoryUrl(value));
    }
    final installed = _stringSet(decoded['installedSources']);
    final disabledDefaults = _stringSet(decoded['disabledDefaultSources']);
    final preferences = await _prefs;
    await preferences.setStringList(
      _repositoriesKey,
      normalized.toList(growable: false),
    );
    await preferences.setStringList(
      _installedSourcesKey,
      installed.toList(growable: false),
    );
    await preferences.setStringList(
      _disabledDefaultsKey,
      disabledDefaults.toList(growable: false),
    );
    _invalidateCatalogCache();
  }

  Set<String> _stringSet(dynamic value) {
    if (value is! List) return <String>{};
    return value
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet();
  }
}
