import 'package:flixquest/video_providers/unified/quickjs/quickjs_stream_mapper.dart';
import 'package:flixquest/video_providers/unified/source_manifest.dart';
import 'package:flixquest/video_providers/unified/stream_option.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mapQuickJsVideoSources', () {
    const source = SourceManifest(
      id: 'allanime',
      name: 'AllAnime',
      repositoryUrl: 'https://repo.example/index.json',
      engine: SourceEngineDescriptor(
        rawType: 'javascript',
        kind: SourceEngineKind.javascript,
        endpoint: 'https://repo.example/providers/allanime.js',
      ),
    );

    test('preserves different mirrors at the same quality and all request metadata', () {
      final streams = mapQuickJsVideoSources(source, <dynamic>[
        <String, dynamic>{
          'url': 'https://cdn-a.example/master.m3u8',
          'quality': '1080p',
          'container': 'hls',
          'headers': <String, String>{'Referer': 'https://host.example/'},
          'kind': 'sub',
          'audioLang': 'ja',
          'subtitles': <dynamic>[
            <String, dynamic>{'url': 'https://cdn-a.example/ar.vtt', 'lang': 'ar', 'format': 'vtt'}
          ],
        },
        <String, dynamic>{
          'url': 'https://cdn-b.example/master.m3u8',
          'quality': '1080p',
          'container': 'hls',
          'headers': <String, String>{'Referer': 'https://other-host.example/'},
          'kind': 'dub',
          'audioLang': 'en',
          'subtitleSkewSeconds': 1.25,
        },
      ]);

      expect(streams, hasLength(2));
      expect(streams[0].quality, '1080p');
      expect(streams[1].quality, '1080p');
      expect(streams[0].url, isNot(streams[1].url));
      expect(streams[0].headers['Referer'], 'https://host.example/');
      expect(streams[0].audioKind, StreamAudioKind.sub);
      expect(streams[0].audioLanguage, 'ja');
      expect(streams[0].subtitles.single.language, 'ar');
      expect(streams[1].audioKind, StreamAudioKind.dub);
      expect(streams[1].subtitleOffsetSeconds, 1.25);
    });

    test('preserves expiry, proxy and descriptive DRM metadata', () {
      final streams = mapQuickJsVideoSources(source, <dynamic>[
        <String, dynamic>{
          'url': 'https://cdn.example/manifest.m3u8',
          'expiresAt': '2026-12-01T12:00:00Z',
          'proxyUrl': 'https://proxy.example/manifest.m3u8',
          'drmType': 'widevine',
        },
      ]);

      expect(streams, hasLength(1));
      expect(streams.single.expiresAt, DateTime.utc(2026, 12, 1, 12));
      expect(streams.single.proxyUrl, 'https://proxy.example/manifest.m3u8');
      expect(streams.single.drmType, 'widevine');
    });

    test('rejects non-http stream URLs and malformed entries', () {
      final streams = mapQuickJsVideoSources(source, <dynamic>[
        <String, dynamic>{'url': 'javascript:alert(1)'},
        <String, dynamic>{'url': 'file:///private/video.mp4'},
        <String, dynamic>{'url': 'https://cdn.example/video.mp4'},
        'not a map',
      ]);
      expect(streams, hasLength(1));
      expect(streams.single.container, StreamContainer.mp4);
    });
  });
}
