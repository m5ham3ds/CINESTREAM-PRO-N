import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flixquest/video_providers/unified/media_identity.dart';
import 'package:flixquest/video_providers/unified/source_engine.dart';
import 'package:flixquest/video_providers/unified/source_manifest.dart';
import 'package:flixquest/video_providers/unified/stremio_addon_provider.dart';
import 'package:flixquest/video_providers/unified/stream_option.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolves direct Stremio streams and preserves headers and subtitles', () async {
    Uri? requestedUri;
    final dio = Dio();
    dio.httpClientAdapter = _JsonAdapter((options) async {
      requestedUri = options.uri;
      return <String, dynamic>{
        'streams': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': '1080p · Dual Audio',
            'title': 'BluRay',
            'url': 'https://cdn.example/release-one.m3u8',
            'behaviorHints': <String, dynamic>{
              'proxyHeaders': <String, dynamic>{
                'request': <String, String>{
                  'Referer': 'https://host.example/',
                  'User-Agent': 'FlixQuest Test',
                },
              },
              'filename': 'release-1080p.m3u8',
            },
            'subtitles': <Map<String, dynamic>>[
              <String, dynamic>{
                'url': 'https://cdn.example/ar.vtt',
                'lang': 'ar',
                'format': 'vtt',
                'default': true,
              },
            ],
          },
          <String, dynamic>{
            'name': '1080p · Dual Audio',
            'url': 'https://cdn-two.example/release-one.mp4',
          },
          <String, dynamic>{
            'name': 'Duplicate mirror',
            'url': 'https://cdn.example/release-one.m3u8',
            'behaviorHints': <String, dynamic>{
              'proxyHeaders': <String, dynamic>{
                'request': <String, String>{
                  'Referer': 'https://host.example/',
                  'User-Agent': 'FlixQuest Test',
                },
              },
            },
          },
          <String, dynamic>{
            'name': '1080p · Dual Audio',
            'title': 'BluRay',
            'url': 'https://cdn.example/release-one.m3u8',
            'behaviorHints': <String, dynamic>{
              'proxyHeaders': <String, dynamic>{
                'request': <String, String>{
                  'Referer': 'https://host.example/',
                  'User-Agent': 'FlixQuest Test',
                },
              },
              'filename': 'release-1080p.m3u8',
            },
            'subtitles': <Map<String, dynamic>>[
              <String, dynamic>{
                'url': 'https://cdn.example/ar.vtt',
                'lang': 'ar',
                'format': 'vtt',
                'default': true,
              },
            ],
          },
          <String, dynamic>{
            'name': 'Torrent release',
            'infoHash': '0123456789abcdef',
          },
        ],
      };
    });

    const source = SourceManifest(
      id: 'test-addon',
      name: 'Test Addon',
      engine: SourceEngineDescriptor(
        rawType: 'stremio',
        kind: SourceEngineKind.stremio,
        endpoint: 'https://addon.example/configured',
        config: <String, dynamic>{
          'types': <String>['movie'],
          'idPrefixes': <String>['tt'],
        },
      ),
    );
    const media = MediaIdentity(
      type: UnifiedMediaType.movie,
      title: 'Example Movie',
      tmdbId: 7,
      externalIds: <String, String>{'imdb': 'tt1234567'},
    );

    final streams = await StremioAddonProvider(dio: dio).getStreams(
      source: source,
      media: media,
    );

    expect(requestedUri!.path,
        '/configured/stream/movie/tt1234567.json');
    // A repeated URL with different stream metadata is retained; the exact
    // duplicate is filtered without collapsing a distinct audio/subtitle option.
    expect(streams, hasLength(3));
    expect(streams.first.container, StreamContainer.hls);
    expect(streams.first.quality, '1080p');
    expect(streams.first.audioKind, StreamAudioKind.dub);
    expect(streams.first.headers['Referer'], 'https://host.example/');
    expect(streams.first.subtitles.single.language, 'ar');
    expect(streams.first.subtitles.single.isDefault, isTrue);
    expect(streams.first.subtitles.single.headers['Referer'],
        'https://host.example/');
    expect(streams.first.audioLanguage, isNull);
    dio.close(force: true);
  });

  test('uses advertised anime ecosystem IDs with episode coordinates', () async {
    Uri? requestedUri;
    final dio = Dio();
    dio.httpClientAdapter = _JsonAdapter((options) async {
      requestedUri = options.uri;
      return <String, dynamic>{'streams': <dynamic>[]};
    });
    const source = SourceManifest(
      id: 'kitsu-addon',
      name: 'Kitsu Addon',
      engine: SourceEngineDescriptor(
        rawType: 'stremio',
        kind: SourceEngineKind.stremio,
        endpoint: 'https://addon.example',
        config: <String, dynamic>{
          'types': <String>['series'],
          'idPrefixes': <String>['kitsu:'],
        },
      ),
    );
    const media = MediaIdentity(
      type: UnifiedMediaType.anime,
      title: 'Example Anime',
      seasonNumber: 1,
      episodeNumber: 4,
      externalIds: <String, String>{'kitsu': '12345'},
    );

    await StremioAddonProvider(dio: dio).getStreams(
      source: source,
      media: media,
    );

    expect(requestedUri!.pathSegments.last, 'kitsu:12345:1:4.json');
    dio.close(force: true);
  });

  test('uses TMDB identifiers only when the add-on advertises a TMDB prefix',
      () async {
    Uri? requestedUri;
    final dio = Dio();
    dio.httpClientAdapter = _JsonAdapter((options) async {
      requestedUri = options.uri;
      return <String, dynamic>{'streams': <dynamic>[]};
    });

    const source = SourceManifest(
      id: 'tmdb-addon',
      name: 'TMDB Addon',
      engine: SourceEngineDescriptor(
        rawType: 'stremio',
        kind: SourceEngineKind.stremio,
        endpoint: 'https://addon.example',
        config: <String, dynamic>{'idPrefixes': <String>['tmdb:']},
      ),
    );
    const media = MediaIdentity(
      type: UnifiedMediaType.series,
      title: 'Example Series',
      tmdbId: 42,
      seasonNumber: 2,
      episodeNumber: 7,
    );

    final streams = await StremioAddonProvider(dio: dio).getStreams(
      source: source,
      media: media,
    );

    expect(streams, isEmpty);
    expect(requestedUri!.pathSegments.last, 'tmdb:42:2:7.json');
    dio.close(force: true);
  });

  test('sequential source queue starts only the provider being resolved',
      () async {
    var activeRequests = 0;
    var peakActiveRequests = 0;
    final dio = Dio();
    dio.httpClientAdapter = _JsonAdapter((options) async {
      activeRequests++;
      if (activeRequests > peakActiveRequests) {
        peakActiveRequests = activeRequests;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      activeRequests--;
      return <String, dynamic>{
        'streams': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': '720p',
            'url': 'https://cdn.example/${options.uri.host}.mp4',
          },
        ],
      };
    });
    final registry = SourceEngineRegistry.standard(dio: dio);
    final sources = <SourceManifest>[
      const SourceManifest(
        id: 'third',
        name: 'Third',
        engine: SourceEngineDescriptor(
          rawType: 'stremio',
          kind: SourceEngineKind.stremio,
          endpoint: 'https://third.example',
          priority: 30,
        ),
      ),
      const SourceManifest(
        id: 'first',
        name: 'First',
        engine: SourceEngineDescriptor(
          rawType: 'stremio',
          kind: SourceEngineKind.stremio,
          endpoint: 'https://first.example',
          priority: 10,
        ),
      ),
      const SourceManifest(
        id: 'second',
        name: 'Second',
        engine: SourceEngineDescriptor(
          rawType: 'stremio',
          kind: SourceEngineKind.stremio,
          endpoint: 'https://second.example',
          priority: 20,
        ),
      ),
    ];
    const media = MediaIdentity(
      type: UnifiedMediaType.movie,
      title: 'Movie',
      externalIds: <String, String>{'imdb': 'tt1234567'},
    );
    final started = <String>[];
    final attempts = await registry.resolveMany(
      sources: sources,
      media: media,
      maxConcurrency: 1,
      onSourceStart: (source) => started.add(source.id),
    );

    expect(started, <String>['first', 'second', 'third']);
    expect(attempts.map((attempt) => attempt.source.id),
        <String>['first', 'second', 'third']);
    expect(peakActiveRequests, 1);
    dio.close(force: true);
  });

  test('registry emits source attempts in priority order while resolving concurrently',
      () async {
    final dio = Dio();
    dio.httpClientAdapter = _JsonAdapter((options) async => <String, dynamic>{
          'streams': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '720p',
              'url': 'https://cdn.example/${options.uri.host}.mp4',
            },
          ],
        });
    final registry = SourceEngineRegistry.standard(dio: dio);
    final sources = <SourceManifest>[
      const SourceManifest(
        id: 'second',
        name: 'Second',
        engine: SourceEngineDescriptor(
          rawType: 'stremio',
          kind: SourceEngineKind.stremio,
          endpoint: 'https://second.example',
          priority: 20,
        ),
      ),
      const SourceManifest(
        id: 'first',
        name: 'First',
        engine: SourceEngineDescriptor(
          rawType: 'stremio',
          kind: SourceEngineKind.stremio,
          endpoint: 'https://first.example',
          priority: 10,
        ),
      ),
    ];
    const media = MediaIdentity(
      type: UnifiedMediaType.movie,
      title: 'Movie',
      externalIds: <String, String>{'imdb': 'tt1234567'},
    );
    final completed = <String>[];
    final attempts = await registry.resolveMany(
      sources: sources,
      media: media,
      maxConcurrency: 2,
      onAttempt: (attempt) => completed.add(attempt.source.id),
    );

    expect(attempts.map((item) => item.source.id), <String>['first', 'second']);
    expect(completed.toSet(), <String>{'first', 'second'});
    expect(attempts.every((item) => item.result.success), isTrue);
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
