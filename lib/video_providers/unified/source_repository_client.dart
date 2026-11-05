import 'package:dio/dio.dart';

import 'source_manifest.dart';
import 'source_repository_parser.dart';

/// Downloads and resolves declarative source repositories on the device.
///
/// The client is intentionally independent of Flutter UI and storage so it can
/// be used by mobile and Android TV flows and tested with a fake Dio adapter.
class SourceRepositoryClient {
  SourceRepositoryClient({Dio? dio, SourceRepositoryParser? parser})
      : _dio = dio ?? _createDio(),
        _parser = parser ?? const SourceRepositoryParser();

  final Dio _dio;
  final SourceRepositoryParser _parser;

  static Dio _createDio() => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 18),
          sendTimeout: const Duration(seconds: 12),
          followRedirects: true,
          maxRedirects: 5,
          responseType: ResponseType.plain,
          headers: const <String, String>{
            'Accept': 'application/json, text/plain;q=0.9, */*;q=0.8',
            'User-Agent': 'FlixQuest-SourceEngine/1.0',
          },
        ),
      );

  Future<SourceRepositoryManifest> fetchRepository(
    String repositoryUrl, {
    CancelToken? cancelToken,
    int maxLinkedLists = 8,
  }) async {
    final normalizedUrl = normalizeRepositoryUrl(repositoryUrl);
    final raw = await _fetchText(normalizedUrl, cancelToken: cancelToken);
    final repository = _parser.parseRepository(
      raw,
      sourceUrl: normalizedUrl,
    );
    if (repository.isStremioAddon) return repository;

    final linkedExtensions = <SourceManifest>[];
    final seenIds = repository.extensions.map((entry) => entry.id).toSet();
    final links = repository.extensionLists.take(maxLinkedLists);
    for (final link in links) {
      final resolved = Uri.parse(normalizedUrl).resolve(link).toString();
      try {
        final linkedRaw = await _fetchText(resolved, cancelToken: cancelToken);
        final items = _parser.parseExtensionList(
          linkedRaw,
          repositoryUrl: normalizedUrl,
        );
        for (final item in items) {
          if (seenIds.add(item.id)) linkedExtensions.add(item);
        }
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) rethrow;
        // One broken linked list must not empty a partially valid repository.
        continue;
      } on FormatException {
        continue;
      }
    }

    final combined = <SourceManifest>[
      ...repository.extensions,
      ...linkedExtensions,
    ];
    final enriched = <SourceManifest>[];
    // Add-on manifests expose the content types and ID prefixes required to
    // choose the correct Stremio stream URL. Limit concurrent metadata lookups
    // so a large index does not open an unbounded burst of network requests.
    for (var start = 0; start < combined.length; start += 3) {
      final batch = combined.skip(start).take(3);
      enriched.addAll(
        await Future.wait(
          batch.map(
            (source) => _enrichStremioSource(
              source,
              cancelToken: cancelToken,
            ),
          ),
        ),
      );
    }

    return SourceRepositoryManifest(
      url: repository.url,
      name: repository.name,
      description: repository.description,
      website: repository.website,
      iconUrl: repository.iconUrl,
      extensions: enriched,
      extensionLists: repository.extensionLists,
    );
  }

  Future<SourceManifest> _enrichStremioSource(
    SourceManifest source, {
    CancelToken? cancelToken,
  }) async {
    if (source.engine.kind != SourceEngineKind.stremio ||
        source.engine.endpoint.trim().isEmpty) {
      return source;
    }

    try {
      final endpoint = Uri.parse(source.engine.endpoint);
      if ((endpoint.scheme != 'https' && endpoint.scheme != 'http') ||
          endpoint.host.isEmpty ||
          endpoint.userInfo.isNotEmpty) {
        return source;
      }
      final endpointSegments = endpoint.pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList();
      if (endpointSegments.isNotEmpty &&
          endpointSegments.last == 'manifest.json') {
        endpointSegments.removeLast();
      }
      final baseEndpoint = endpoint
          .replace(pathSegments: endpointSegments)
          .toString();
      final manifestUrl = endpoint
          .replace(
            pathSegments: <String>[...endpointSegments, 'manifest.json'],
          )
          .toString();
      final rawManifest = await _fetchText(
        manifestUrl,
        cancelToken: cancelToken,
      );
      final parsed = _parser.parseRepository(
        rawManifest,
        sourceUrl: manifestUrl,
      );
      if (!parsed.isStremioAddon || parsed.extensions.isEmpty) return source;
      final manifestSource = parsed.extensions.first;
      final engine = SourceEngineDescriptor(
        rawType: 'stremio',
        kind: manifestSource.engine.kind,
        endpoint: baseEndpoint,
        priority: source.engine.priority,
        language: source.engine.language ?? manifestSource.engine.language,
        qualityFilter:
            source.engine.qualityFilter ?? manifestSource.engine.qualityFilter,
        movieUrl: source.engine.movieUrl ?? manifestSource.engine.movieUrl,
        tvUrl: source.engine.tvUrl ?? manifestSource.engine.tvUrl,
        config: <String, dynamic>{
          ...source.engine.config,
          ...manifestSource.engine.config,
        },
      );
      return SourceManifest(
        id: source.id,
        name: source.name,
        description: source.description,
        version: source.version,
        versionCode: source.versionCode,
        apiVersion: source.apiVersion,
        language: source.language,
        authors: source.authors,
        tags: source.tags,
        homepage: source.homepage ?? manifestSource.homepage,
        iconUrl: source.iconUrl ?? manifestSource.iconUrl,
        repositoryUrl: source.repositoryUrl,
        enabled: source.enabled && manifestSource.enabled,
        installedByDefault: source.installedByDefault,
        isFallback: source.isFallback,
        isNsfw: source.isNsfw,
        status: source.status,
        updatedAt: source.updatedAt,
        engine: engine,
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      // Keep an indexed Stremio source visible if its metadata host is down.
      return source;
    } catch (_) {
      // Runtime fallback can still try its documented default ID convention.
      return source;
    }
  }

  Future<String> _fetchText(
    String url, {
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get<String>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 18),
        validateStatus: (status) => status != null && status >= 200 && status < 300,
      ),
    );
    final body = response.data;
    if (body == null || body.trim().isEmpty) {
      throw const FormatException('The source repository returned an empty response.');
    }
    return body;
  }

  /// Accepts only explicit HTTP(S) URLs. Relative linked-list paths are resolved
  /// against the repository URL by [fetchRepository].
  static String normalizeRepositoryUrl(String input) {
    final value = input.trim();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException(
        'Repository URL must be a valid HTTP or HTTPS address.',
      );
    }
    return uri.toString();
  }
}
