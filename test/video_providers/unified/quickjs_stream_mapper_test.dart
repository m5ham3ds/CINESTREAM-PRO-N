import 'package:flixquest/video_providers/unified/quickjs/quickjs_stream_mapper.dart';
import 'package:flixquest/video_providers/unified/source_manifest.dart';
import 'package:flixquest/video_providers/unified/stream_option.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const source = SourceManifest(
    id: 'zangetsu-sample',
    name: 'Zangetsu sample',
    engine: SourceEngineDescriptor(
      rawType: 'javascript',
      kind: SourceEngineKind.javascript,
      endpoint: 'https://example.com/provider.js',
      priority: 10,
    ),
  );

  test('maps Zangetsu VideoSource fields without losing player metadata', () {
    final streams = mapQuickJsVideoSources(source, <dynamic>[
      <String, dynamic>{
        'url': 'https://cdn.example.com/episode/master.m3u8?token=abc',
        'quality': '1080p',
        'label': 'Primary HLS',
        'container': 'hls',
        'headers': <String, String>{
          'Referer': 'https://embed.example.com/',
          'User-Agent': 'TestAgent/1.0',
        },
        'kind': 'sub',
        'audioLang': 'ja',
        'subtitles': <dynamic>[
          <String, dynamic>{
            'url': 'https://cdn.example.com/subs/en.vtt',
            'lang': 'en',
            'label': 'English',
            'format': 'vtt',
            'default': true,
          },
        ],
        'subtitleSkewSeconds': 0.75,
        'subtitleSkewAfterSeconds': 42,
      },
    ]);

    expect(streams, hasLength(1));
    final stream = streams.single;
    expect(stream.url, contains('master.m3u8'));
    expect(stream.container, StreamContainer.hls);
    expect(stream.quality, '1080p');
    expect(stream.headers['Referer'], 'https://embed.example.com/');
    expect(stream.headers['User-Agent'], 'TestAgent/1.0');
    expect(stream.audioKind, StreamAudioKind.sub);
    expect(stream.audioLanguage, 'ja');
    expect(stream.subtitles, hasLength(1));
    expect(stream.subtitles.single.language, 'en');
    expect(stream.subtitles.single.label, 'English');
    expect(stream.subtitles.single.format, 'vtt');
    expect(stream.subtitles.single.isDefault, isTrue);
    expect(stream.subtitleOffsetSeconds, 0.75);
    expect(stream.subtitleOffsetAfterSeconds, 42);
  });

  test('rejects non-HTTP stream entries and empty getVideoSources payloads', () {
    final streams = mapQuickJsVideoSources(source, <dynamic>[
      <String, dynamic>{'url': 'magnet:?xt=urn:btih:example'},
      <String, dynamic>{'url': 'javascript:alert(1)'},
      <String, dynamic>{'url': 'not a URL'},
    ]);

    expect(streams, isEmpty);
    expect(mapQuickJsVideoSources(source, null), isEmpty);
  });
}
