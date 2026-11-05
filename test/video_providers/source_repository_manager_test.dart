import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flixquest/video_providers/unified/source_manifest.dart';
import 'package:flixquest/video_providers/unified/source_repository_client.dart';
import 'package:flixquest/video_providers/unified/source_repository_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Keep these tests isolated from the production first-run OpenStream seed.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'unified_source_default_repository_seeded_v1': true,
    });
  });

  test('catalog entries are not resolved until explicitly installed', () async {
    final dio = _repositoryDio();
    final preferences = await SharedPreferences.getInstance();
    final manager = SourceRepositoryManager(
      client: SourceRepositoryClient(dio: dio),
      preferences: preferences,
    );
    await manager.addRepository('https://repo.example/index.json');

    final discovered = await manager.sync();
    expect(discovered.catalog, hasLength(1));
    expect(discovered.sources, isEmpty);

    await manager.installSource(discovered.catalog.single);
    final installed = await manager.sync();
    expect(installed.sources, hasLength(1));
    expect(installed.sources.single.id, 'catalog-addon');

    await manager.uninstallSource(installed.sources.single);
    final uninstalled = await manager.sync();
    expect(uninstalled.catalog, hasLength(1));
    expect(uninstalled.sources, isEmpty);
    dio.close(force: true);
  });

  test('reuses the source catalogue within its cache window and force refreshes',
      () async {
    var repositoryRequests = 0;
    final dio = Dio();
    dio.httpClientAdapter = _JsonAdapter((options) async {
      if (options.uri.host == 'repo.example') repositoryRequests++;
      if (options.uri.host == 'repo.example') {
        return <String, dynamic>{
          'name': 'Cached Repository',
          'extensions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'cached-addon',
              'name': 'Cached Addon',
              'engine': <String, dynamic>{
                'type': 'stremio',
                'endpoint': 'https://addon.example',
              },
            },
          ],
        };
      }
      return <String, dynamic>{
        'id': 'org.cached.addon',
        'name': 'Cached Addon',
        'resources': <String>['stream'],
        'types': <String>['movie'],
        'idPrefixes': <String>['tt'],
      };
    });
    final preferences = await SharedPreferences.getInstance();
    final manager = SourceRepositoryManager(
      client: SourceRepositoryClient(dio: dio),
      preferences: preferences,
    );
    await manager.addRepository('https://repo.example/index.json');

    await manager.sync();
    final firstRequestCount = repositoryRequests;
    await manager.sync();
    expect(repositoryRequests, firstRequestCount);

    await manager.sync(forceRefresh: true);
    expect(repositoryRequests, greaterThan(firstRequestCount));
    dio.close(force: true);
  });

  test('removing a repository clears its saved source installation state',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final manager = SourceRepositoryManager(preferences: preferences);
    const source = SourceManifest(
      id: 'installed-addon',
      name: 'Installed Addon',
      repositoryUrl: 'https://repo.example/index.json',
      engine: SourceEngineDescriptor(
        rawType: 'stremio',
        kind: SourceEngineKind.stremio,
        endpoint: 'https://addon.example',
      ),
    );
    await manager.addRepository('https://repo.example/index.json');
    await manager.installSource(source);
    expect(await manager.installedSourceKeys(), contains(source.stableKey));

    await manager.removeRepository('https://repo.example/index.json');
    expect(await manager.repositoryUrls(), isEmpty);
    expect(await manager.installedSourceKeys(), isEmpty);
  });

  test('directly added Stremio manifest is enabled by default and can be removed',
      () async {
    final dio = Dio();
    dio.httpClientAdapter = _JsonAdapter((options) async => <String, dynamic>{
          'id': 'direct-addon',
          'name': 'Direct Addon',
          'resources': <String>['stream'],
          'types': <String>['movie'],
        });
    final preferences = await SharedPreferences.getInstance();
    final manager = SourceRepositoryManager(
      client: SourceRepositoryClient(dio: dio),
      preferences: preferences,
    );
    await manager.addRepository('https://addon.example/manifest.json');

    final added = await manager.sync();
    expect(added.catalog.single.installedByDefault, isTrue);
    expect(added.sources, hasLength(1));

    await manager.uninstallSource(added.sources.single);
    expect((await manager.sync()).sources, isEmpty);

    await manager.installSource(added.catalog.single);
    expect((await manager.sync()).sources, hasLength(1));
    dio.close(force: true);
  });
}

Dio _repositoryDio() {
  final dio = Dio();
  dio.httpClientAdapter = _JsonAdapter((options) async {
    if (options.uri.host == 'repo.example') {
      return <String, dynamic>{
        'name': 'Test Repository',
        'extensions': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'catalog-addon',
            'name': 'Catalog Addon',
            'engine': <String, dynamic>{
              'type': 'stremio',
              'endpoint': 'https://addon.example',
            },
          },
        ],
      };
    }
    return <String, dynamic>{
      'id': 'org.catalog.addon',
      'name': 'Catalog Addon',
      'resources': <String>['stream'],
      'types': <String>['movie'],
      'idPrefixes': <String>['tt'],
    };
  });
  return dio;
}

class _JsonAdapter implements HttpClientAdapter {
  _JsonAdapter(this.handler);

  final Future<Map<String, dynamic>> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = await handler(options);
    return ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
