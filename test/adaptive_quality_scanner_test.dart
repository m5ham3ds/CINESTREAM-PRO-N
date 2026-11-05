import 'package:flixquest/video_providers/adaptive_quality_scanner.dart';
import 'package:flixquest/video_providers/common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('parses every HLS variant height and sorts it highest first', () {
    const manifest = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1800000,RESOLUTION=1280x720
720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3500000,RESOLUTION=1920x1080
1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=2560x1440
1440/index.m3u8
''';
    expect(AdaptiveQualityScanner.parseHlsHeights(manifest),
        <int>[1440, 1080, 720, 360]);
  });



  test('uses the HLS NAME attribute when RESOLUTION is not declared', () {
    const manifest = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=3500000,NAME="1080p"
1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=900000,NAME="360p"
360/index.m3u8
''';
    expect(AdaptiveQualityScanner.parseHlsHeights(manifest),
        <int>[1080, 360]);
  });

  test('requests an adaptive manifest with the provider request headers', () async {
    const manifest = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=3500000,RESOLUTION=1920x1080
1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1800000,RESOLUTION=1280x720
720/index.m3u8
''';
    final client = MockClient((request) async {
      expect(request.headers['referer'], 'https://provider.example/');
      expect(request.headers['x-token'], 'source-token');
      return http.Response(manifest, 200);
    });
    final scanner = AdaptiveQualityScanner(client: client);
    try {
      final heights = await scanner.scan(RegularVideoLinks(
        url: 'https://provider.example/master.m3u8',
        quality: 'Auto',
        server: 'Sova',
        isM3U8: true,
        isAdaptive: true,
        headers: const <String, String>{
          'Referer': 'https://provider.example/',
          'X-Token': 'source-token',
        },
      ));
      expect(heights, <int>[1080, 720]);
    } finally {
      scanner.dispose();
    }
  });

  test('parses DASH Representation heights', () {
    const manifest = '''<?xml version="1.0"?>
<MPD><Period><AdaptationSet>
<Representation id="1" bandwidth="800000" width="640" height="360" />
<Representation id="2" bandwidth="1800000" width="1280" height="720" />
<Representation id="3" bandwidth="3500000" width="1920" height="1080" />
</AdaptationSet></Period></MPD>
''';
    expect(AdaptiveQualityScanner.parseDashHeights(manifest),
        <int>[1080, 720, 360]);
  });

  test('sniffs extensionless HLS masters and follows nested variant playlists', () async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      if (request.url.path == '/edge/master') {
        return http.Response(
          '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=900000

# provider comment between the tag and the URI
levels/high/index.m3u8
''',
          200,
          headers: const {'content-type': 'application/vnd.apple.mpegurl'},
          request: request,
        );
      }
      return http.Response(
        '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080
1080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=854x480
480.m3u8
''',
        200,
        headers: const {'content-type': 'application/vnd.apple.mpegurl'},
        request: request,
      );
    });
    final scanner = AdaptiveQualityScanner(client: client);
    try {
      final heights = await scanner.scan(RegularVideoLinks(
        url: 'https://provider.example/edge/master',
        quality: 'Auto · Phoenix',
        server: 'Phoenix',
        isAdaptive: true,
        headers: const {'Referer': 'https://provider.example/'},
      ));
      expect(heights, <int>[1080, 480]);
      expect(requests, hasLength(2));
      expect(requests.last.path, '/edge/levels/high/index.m3u8');
    } finally {
      scanner.dispose();
    }
  });

  test('infers a variant height from explicit HLS rendition path segments', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/master') {
        return http.Response(
          '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2200000

# provider omits RESOLUTION and NAME
renditions/1080p/index.m3u8
''',
          200,
          headers: const {'content-type': 'application/vnd.apple.mpegurl'},
          request: request,
        );
      }
      return http.Response('', 404, request: request);
    });
    final scanner = AdaptiveQualityScanner(client: client);
    try {
      final heights = await scanner.scan(RegularVideoLinks(
        url: 'https://provider.example/master',
        quality: 'Auto · Jett',
      ));
      expect(heights, <int>[1080]);
    } finally {
      scanner.dispose();
    }
  });

  test('sniffs an extensionless DASH manifest from its response content type', () async {
    final client = MockClient((request) async => http.Response(
          '''<MPD><Period><AdaptationSet>
<Representation id="low" height="360" />
<Representation id="high" height="1080" />
</AdaptationSet></Period></MPD>''',
          200,
          headers: const {'content-type': 'application/dash+xml'},
          request: request,
        ));
    final scanner = AdaptiveQualityScanner(client: client);
    try {
      final heights = await scanner.scan(RegularVideoLinks(
        url: 'https://provider.example/stream?id=42',
        quality: 'Adaptive',
        isAdaptive: true,
      ));
      expect(heights, <int>[1080, 360]);
    } finally {
      scanner.dispose();
    }
  });

  test('ignores a media playlist with no variant stream declarations', () {
    const manifest = '''#EXTM3U
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
segment-001.ts
''';
    expect(AdaptiveQualityScanner.parseHlsHeights(manifest), isEmpty);
  });
}
