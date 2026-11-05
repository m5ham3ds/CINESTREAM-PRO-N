import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flixquest/video_providers/unified/source_repository_client.dart';
import 'package:flixquest/video_providers/unified/source_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('enriches Stremio entries from OpenStream-style indexes with manifest IDs',
      () async {
    final requested = <String>[];
    final dio = Dio();
    dio.httpClientAdapter = _JsonAdapter((options) async {
      requested.add(options.uri.toString());
      if (options.uri.host == 'repo.example') {
        return <String, dynamic>{
          'manifestVersion': 1,
          'name': 'Test Repository',
          'extensions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'test-addon',
              'name': 'Test Addon',
              'engine': <String, dynamic>{
                'type': 'stremio',
                'endpoint': 'https://addon.example/config',
                'priority': 15,
              },
            },
          ],
        };
      }
      return <String, dynamic>{
        'id': 'org.test.addon',
        'name': 'Test Addon Manifest',
        'version': '1.2.0',
        'resources': <String>['stream'],
        'types': <String>['series'],
        'idPrefixes': <String>['tmdb:'],
      };
    });

    final repository = await SourceRepositoryClient(dio: dio).fetchRepository(
      'https://repo.example/index.json',
    );
    final source = repository.extensions.single;

    expect(requested, <String>[
      'https://repo.example/index.json',
      'https://addon.example/config/manifest.json',
    ]);
    expect(source.engine.kind, SourceEngineKind.stremio);
    expect(source.engine.endpoint, 'https://addon.example/config');
    expect(source.engine.config['types'], <String>['series']);
    expect(source.engine.config['idPrefixes'], <String>['tmdb:']);
    expect(source.engine.priority, 15);
    dio.close(force: true);
  });
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
