import 'dart:convert';

import 'source_manifest.dart';

/// Tolerant parser for declarative source repositories.
///
/// Accepted shapes:
/// - OpenStream-style `{ manifestVersion, extensions: [...] }`;
/// - Zangetsu-style `{ name, description, sources: [...] }` JavaScript repos;
/// - a raw array of extension entries;
/// - `{ extensions: [...] }` linked-list documents;
/// - a plain Stremio add-on `manifest.json`.
///
/// Invalid individual entries are skipped so one bad extension does not hide
/// the rest of a repository.
class SourceRepositoryParser {
  const SourceRepositoryParser();

  SourceRepositoryManifest parseRepository(
    String raw, {
    required String sourceUrl,
  }) {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return SourceRepositoryManifest(
        url: sourceUrl,
        name: _repositoryName(sourceUrl),
        extensions: _parseEntries(decoded, sourceUrl),
      );
    }
    if (decoded is! Map) {
      throw const FormatException(
        'A source repository must be a JSON object or array.',
      );
    }

    final root = Map<String, dynamic>.from(decoded);
    if (_isStremioManifest(root)) {
      return _parseStremioManifest(root, sourceUrl);
    }

    final entries = root['extensions'];
    final extensionLists = root['extensionLists'];
    final parsedExtensions =
        _parseEntries(entries is List ? entries : const [], sourceUrl);
    final parsedJsSources = _parseZangetsuSources(
      root['sources'] is List ? root['sources'] as List : const <dynamic>[],
      sourceUrl,
    );
    final combined = <SourceManifest>[];
    final seen = <String>{};
    for (final source in <SourceManifest>[
      ...parsedExtensions,
      ...parsedJsSources,
    ]) {
      if (seen.add(source.id)) combined.add(source);
    }
    return SourceRepositoryManifest(
      url: sourceUrl,
      name: _text(root['name']) ?? _repositoryName(sourceUrl),
      description: _text(root['description']) ?? '',
      website: _text(root['website']),
      iconUrl: _text(root['iconUrl']),
      extensions: combined,
      extensionLists: extensionLists is List
          ? extensionLists
              .map(_text)
              .whereType<String>()
              .where((value) => value.isNotEmpty)
              .toList(growable: false)
          : const <String>[],
    );
  }

  List<SourceManifest> parseExtensionList(
    String raw, {
    required String repositoryUrl,
  }) {
    final decoded = jsonDecode(raw);
    final entries = decoded is List
        ? decoded
        : decoded is Map && decoded['extensions'] is List
            ? decoded['extensions'] as List
            : const <dynamic>[];
    return _parseEntries(entries, repositoryUrl);
  }

  List<SourceManifest> _parseEntries(
    List<dynamic> entries,
    String repositoryUrl,
  ) {
    final parsed = <SourceManifest>[];
    final seen = <String>{};
    for (final rawEntry in entries) {
      if (rawEntry is! Map) continue;
      final entry = Map<String, dynamic>.from(rawEntry);
      final id = _text(entry['id']);
      final name = _text(entry['name']);
      final rawEngine = entry['engine'];
      if (id == null || name == null || rawEngine is! Map) continue;
      if (!seen.add(id)) continue;

      final engineMap = Map<String, dynamic>.from(rawEngine);
      final rawType = _text(engineMap['type']) ?? '';
      final engineKind = sourceEngineKindFrom(rawType);
      final endpoint = _text(engineMap['endpoint']) ?? '';
      final movieUrl = _text(engineMap['movieUrl']);
      final tvUrl = _text(engineMap['tvUrl']);
      final isValidEngine = switch (engineKind) {
        SourceEngineKind.stremio => _isHttpEndpoint(endpoint),
        SourceEngineKind.vidkingDirect => _isVidkingRoute(endpoint),
        SourceEngineKind.vidkingWebView => true,
        SourceEngineKind.webEmbed =>
          _isHttpsTemplate(movieUrl ?? '') || _isHttpsTemplate(tvUrl ?? ''),
        SourceEngineKind.animeSite => _isHttpsEndpoint(endpoint),
        SourceEngineKind.javascript => _isHttpEndpoint(endpoint),
        _ => false,
      };
      final resolvedEngineKind = isValidEngine
          ? engineKind
          : SourceEngineKind.unsupported;
      final config = Map<String, dynamic>.from(engineMap)
        ..remove('type')
        ..remove('endpoint')
        ..remove('priority')
        ..remove('language')
        ..remove('qualityFilter')
        ..remove('movieUrl')
        ..remove('tvUrl');
      parsed.add(
        SourceManifest(
          id: id,
          name: name,
          description: _text(entry['description']) ?? '',
          version: _text(entry['version']) ?? '1.0.0',
          versionCode: _integer(entry['versionCode'], fallback: 1),
          apiVersion: _integer(entry['apiVersion'], fallback: 1),
          language: _text(entry['language']) ?? 'Multi',
          authors: _stringList(entry['authors']),
          tags: _stringList(entry['tags'])
              .map((tag) => tag.toLowerCase())
              .toList(growable: false),
          homepage: _text(entry['homepage']),
          iconUrl: _text(entry['iconUrl']),
          repositoryUrl: repositoryUrl,
          enabled: entry['enabled'] != false,
          installedByDefault: entry['installedByDefault'] == true,
          isFallback: entry['fallback'] == true ||
              _stringList(entry['tags']).any(
                (tag) => tag.trim().toLowerCase() == 'fallback',
              ) ||
              engineKind == SourceEngineKind.vidkingWebView,
          isNsfw: entry['nsfw'] == true,
          status: _integer(entry['status'], fallback: 1).clamp(0, 3).toInt(),
          updatedAt: _dateTime(entry['updatedAt']),
          engine: SourceEngineDescriptor(
            rawType: rawType,
            kind: resolvedEngineKind,
            endpoint: endpoint,
            priority: _integer(engineMap['priority'], fallback: 50),
            language: _text(engineMap['language']),
            qualityFilter: _text(engineMap['qualityFilter']),
            movieUrl: movieUrl,
            tvUrl: tvUrl,
            config: config,
          ),
        ),
      );
    }
    return parsed;
  }

  List<SourceManifest> _parseZangetsuSources(
    List<dynamic> entries,
    String repositoryUrl,
  ) {
    final parsed = <SourceManifest>[];
    final seen = <String>{};
    for (final rawEntry in entries) {
      if (rawEntry is! Map) continue;
      final entry = Map<String, dynamic>.from(rawEntry);
      final id = _text(entry['id']);
      final name = _text(entry['name']);
      final file = _text(entry['file']);
      if (id == null || name == null || file == null || !seen.add(id)) {
        continue;
      }
      final resolvedFile = Uri.tryParse(file);
      final scriptUrl = resolvedFile != null &&
              (resolvedFile.scheme == 'https' || resolvedFile.scheme == 'http') &&
              resolvedFile.host.isNotEmpty &&
              resolvedFile.userInfo.isEmpty
          ? resolvedFile.toString()
          : Uri.parse(repositoryUrl).resolve(file).toString();
      final validScriptUrl = _isHttpEndpoint(scriptUrl) &&
          (scriptUrl.toLowerCase().split('?').first.endsWith('.js') ||
              scriptUrl.toLowerCase().split('?').first.endsWith('.mjs'));
      final logoValue = _text(entry['logo']);
      final logoUrl = logoValue == null
          ? null
          : _resolveRepositoryAsset(repositoryUrl, logoValue);
      final language = _text(entry['lang']) ?? 'Multi';
      final providerType = (_text(entry['type']) ?? 'all').toLowerCase();

      parsed.add(
        SourceManifest(
          id: id,
          name: name,
          description: _text(entry['description']) ??
              'JavaScript provider from a Zangetsu-compatible repository.',
          version: _text(entry['version']) ?? '1.0.0',
          language: language,
          authors: _stringList(entry['authors']),
          tags: <String>[
            'javascript',
            if (providerType != 'all') providerType,
            if (_boolean(entry['nsfw'])) 'nsfw',
          ],
          homepage: _text(entry['homepage']),
          iconUrl: logoUrl,
          repositoryUrl: repositoryUrl,
          enabled: validScriptUrl,
          installedByDefault: false,
          isNsfw: _boolean(entry['nsfw']),
          engine: SourceEngineDescriptor(
            rawType: 'javascript',
            kind: validScriptUrl
                ? SourceEngineKind.javascript
                : SourceEngineKind.unsupported,
            endpoint: validScriptUrl ? scriptUrl : '',
            priority: _integer(entry['priority'], fallback: 50),
            language: language,
            config: <String, dynamic>{
              'providerType': providerType,
              'version': _text(entry['version']) ?? '1.0.0',
              'sourceFile': file,
              'runtimeContract': 'zangetsu-js-v1',
            },
          ),
        ),
      );
    }
    return parsed;
  }

  String _resolveRepositoryAsset(String repositoryUrl, String path) {
    final supplied = Uri.tryParse(path);
    if (supplied != null &&
        (supplied.scheme == 'https' || supplied.scheme == 'http') &&
        supplied.host.isNotEmpty &&
        supplied.userInfo.isEmpty) {
      return supplied.toString();
    }
    return Uri.parse(repositoryUrl).resolve(path).toString();
  }

  static bool _boolean(dynamic value) => value == true || value == 1;

  bool _isHttpEndpoint(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  bool _isHttpsEndpoint(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  bool _isHttpsTemplate(String value) {
    final normalized = value.replaceAll(RegExp(r'\{[A-Za-z][A-Za-z0-9]*\}'), 'placeholder');
    return _isHttpsEndpoint(normalized);
  }

  bool _isVidkingRoute(String value) {
    final route = value.trim().replaceAll('\\', '/');
    final uri = Uri.tryParse(route);
    return route.isNotEmpty &&
        uri != null &&
        !uri.hasScheme &&
        !uri.hasAuthority &&
        !route.startsWith('/') &&
        uri.pathSegments.isNotEmpty &&
        !uri.pathSegments.any((segment) => segment == '.' || segment == '..');
  }

  bool _isStremioManifest(Map<String, dynamic> root) =>
      root.containsKey('id') && root.containsKey('resources');

  SourceRepositoryManifest _parseStremioManifest(
    Map<String, dynamic> root,
    String sourceUrl,
  ) {
    final addonId = _text(root['id']);
    if (addonId == null) {
      throw const FormatException('Stremio manifest is missing its id.');
    }

    final resources = root['resources'];
    var supportsStreams = false;
    final streamResourceMaps = <Map<String, dynamic>>[];
    if (resources is List) {
      for (final resource in resources) {
        if (resource is String && resource.toLowerCase() == 'stream') {
          supportsStreams = true;
        } else if (resource is Map &&
            _text(resource['name'])?.toLowerCase() == 'stream') {
          supportsStreams = true;
          streamResourceMaps.add(Map<String, dynamic>.from(resource));
        }
      }
    }

    // Stremio v1 manifests commonly declare `types` and `idPrefixes` on the
    // stream resource itself rather than at the manifest root. Prefer the
    // root-level values when present, otherwise merge the stream-resource
    // declarations so IDs are never guessed from unrelated catalog resources.
    final rootTypes = _stringList(root['types']);
    final resourceTypes = <String>{
      for (final resource in streamResourceMaps)
        ..._stringList(resource['types']),
    };
    final types = (rootTypes.isNotEmpty ? rootTypes : resourceTypes.toList())
        .map((type) => type.toLowerCase())
        .toSet();
    final rootPrefixes = _stringList(root['idPrefixes']);
    final resourcePrefixes = <String>{
      for (final resource in streamResourceMaps)
        ..._stringList(resource['idPrefixes']),
    };
    final idPrefixes = rootPrefixes.isNotEmpty
        ? rootPrefixes
        : resourcePrefixes.toList(growable: false);
    final baseUrl = _stremioBaseUrl(sourceUrl);
    final behaviorHints = root['behaviorHints'] is Map
        ? Map<String, dynamic>.from(root['behaviorHints'] as Map)
        : const <String, dynamic>{};
    final needsConfiguration = behaviorHints['configurable'] == true ||
        behaviorHints['configurationRequired'] == true;
    final playable = supportsStreams && baseUrl != null && !needsConfiguration;
    final manifest = SourceManifest(
      id: addonId,
      name: _text(root['name']) ?? addonId,
      description: _text(root['description']) ?? '',
      version: _text(root['version']) ?? '1.0.0',
      language: 'Multi',
      authors: <String>[_hostOf(sourceUrl)]
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      tags: <String>[
        'stremio',
        'addon',
        if (types.contains('movie')) 'movies',
        if (types.contains('series')) 'series',
      ],
      homepage: _text(root['homepage']),
      iconUrl: _text(root['logo']),
      repositoryUrl: sourceUrl,
      enabled: playable,
      // A direct manifest URL was explicitly added by the user. Treat it as
      // installed by default, unlike entries merely discovered in a catalog.
      installedByDefault: true,
      engine: SourceEngineDescriptor(
        rawType: 'stremio',
        kind: playable ? SourceEngineKind.stremio : SourceEngineKind.unsupported,
        endpoint: baseUrl ?? sourceUrl,
        priority: 40,
        config: <String, dynamic>{
          if (types.isNotEmpty) 'types': types.toList(growable: false),
          if (idPrefixes.isNotEmpty) 'idPrefixes': idPrefixes,
          if (root['catalogs'] != null) 'catalogs': root['catalogs'],
          'resources': resources,
          'needsConfiguration': needsConfiguration,
        },
      ),
    );

    return SourceRepositoryManifest(
      url: sourceUrl,
      name: manifest.name,
      description: manifest.description,
      website: manifest.homepage,
      iconUrl: manifest.iconUrl,
      extensions: <SourceManifest>[manifest],
      isStremioAddon: true,
    );
  }

  String? _stremioBaseUrl(String sourceUrl) {
    final uri = Uri.tryParse(sourceUrl);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    var path = uri.path;
    if (path.endsWith('/manifest.json')) {
      path = path.substring(0, path.length - '/manifest.json'.length);
    } else if (path.endsWith('manifest.json')) {
      path = path.substring(0, path.length - 'manifest.json'.length);
    }
    return uri.replace(path: path.replaceFirst(RegExp(r'/+$'), '')).toString();
  }

  String _hostOf(String url) => Uri.tryParse(url)?.host ?? '';

  String _repositoryName(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return 'Source repository';
    return uri.host.isEmpty ? 'Source repository' : uri.host;
  }

  static String? _text(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static int _integer(dynamic value, {required int fallback}) {
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? fallback;
  }

  static List<String> _stringList(dynamic value) {
    if (value is! List) return const <String>[];
    return value
        .map(_text)
        .whereType<String>()
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static DateTime? _dateTime(dynamic value) {
    if (value is DateTime) return value;
    if (value is num) {
      final millis = value > 1000000000000
          ? value.toInt()
          : (value * 1000).toInt();
      return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    }
    if (value is String && value.trim().isNotEmpty) {
      return DateTime.tryParse(value.trim());
    }
    return null;
  }
}
