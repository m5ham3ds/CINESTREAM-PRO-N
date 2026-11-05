import 'package:flixquest/video_providers/common.dart';
import 'package:flixquest/video_providers/quality_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 3, 12);

  test('treats adaptive labels with provider suffixes as adaptive masters', () {
    final catalog = PlaybackQualityCatalog.collect(
      linksByProvider: <String, List<RegularVideoLinks>>{
        'jett': <RegularVideoLinks>[
          RegularVideoLinks(
            url: 'https://jett.example/master',
            quality: 'Auto · Jett',
            server: 'Jett',
          ),
        ],
      },
      now: now,
    );

    expect(catalog, hasLength(1));
    expect(catalog.single.isAdaptive, isTrue);
    expect(catalog.single.qualityLabel, 'Auto');
  });

  test('collects every quality from every provider, including nonstandard heights', () {
    final links = <String, List<RegularVideoLinks>>{
      'jett': <RegularVideoLinks>[
        RegularVideoLinks(
          url: 'https://jett.example/2160.mpd',
          quality: '2160p',
          server: 'Jett',
          providerCode: 'jett',
          isDash: true,
        ),
        RegularVideoLinks(
          url: 'https://jett.example/1440.mpd',
          quality: '1440p',
          server: 'Jett',
          providerCode: 'jett',
          isDash: true,
        ),
        RegularVideoLinks(
          url: 'https://jett.example/1080.mpd',
          quality: '1080p',
          server: 'Jett',
          providerCode: 'jett',
          isDash: true,
        ),
        RegularVideoLinks(
          url: 'https://jett.example/360.mp4',
          quality: '360p',
          server: 'Jett',
          providerCode: 'jett',
        ),
        RegularVideoLinks(
          url: 'https://jett.example/270.mp4',
          quality: '270',
          server: 'Jett',
          providerCode: 'jett',
        ),
      ],
      'sova': <RegularVideoLinks>[
        RegularVideoLinks(
          url: 'https://sova.example/1080.m3u8',
          quality: '1080p',
          server: 'Sova',
          providerCode: 'sova',
          isM3U8: true,
        ),
        RegularVideoLinks(
          url: 'https://sova.example/720.mp4',
          quality: '720p',
          server: 'Sova',
          providerCode: 'sova',
        ),
        RegularVideoLinks(
          url: 'https://sova.example/480.mp4',
          quality: '480p',
          server: 'Sova',
          providerCode: 'sova',
        ),
        RegularVideoLinks(
          url: 'https://sova.example/180.mp4',
          quality: '180',
          server: 'Sova',
          providerCode: 'sova',
        ),
      ],
      'phoenix': <RegularVideoLinks>[
        RegularVideoLinks(
          url: 'https://phoenix.example/master.m3u8',
          quality: 'Auto',
          server: 'Phoenix',
          providerCode: 'phoenix',
          isM3U8: true,
          isAdaptive: true,
          availableHeights: <int>[540, 360],
        ),
      ],
      'unified:sources': <RegularVideoLinks>[
        // The aggregate bucket mirrors originals and must not duplicate them.
        RegularVideoLinks(
          url: 'https://jett.example/1080.mpd',
          quality: '1080p',
          server: 'Jett',
          providerCode: 'jett',
          isDash: true,
        ),
      ],
    };

    final catalog = PlaybackQualityCatalog.collect(
      linksByProvider: links,
      now: now,
    );
    final urls = catalog.map((entry) => entry.link.url).toList();
    final heights = catalog.map((entry) => entry.height).toList();

    expect(urls, containsAll(<String>[
      'https://jett.example/2160.mpd',
      'https://jett.example/1440.mpd',
      'https://jett.example/1080.mpd',
      'https://sova.example/1080.m3u8',
      'https://sova.example/720.mp4',
      'https://sova.example/480.mp4',
      'https://phoenix.example/master.m3u8',
      'https://jett.example/360.mp4',
      'https://jett.example/270.mp4',
      'https://sova.example/180.mp4',
    ]));
    expect(urls.where((url) => url == 'https://jett.example/1080.mpd'), hasLength(1));
    expect(urls.where((url) => url == 'https://sova.example/1080.m3u8'), hasLength(1));
    expect(heights.first, 2160);
    expect(heights, containsAll(<int>[1440, 1080, 720, 540, 480, 360, 270, 180]));
    final phoenixEntries = catalog
        .where((entry) => entry.link.server == 'Phoenix')
        .toList(growable: false);
    expect(phoenixEntries.map((entry) => entry.qualityLabel),
        containsAll(<String>['Auto', '540p', '360p']));
    expect(phoenixEntries.where((entry) => entry.adaptiveTargetHeight != null)
        .map((entry) => entry.adaptiveTargetHeight), containsAll(<int>[540, 360]));
  });

  test('expands supplied adaptive heights even when legacy flag is missing', () {
    final catalog = PlaybackQualityCatalog.collect(
      linksByProvider: <String, List<RegularVideoLinks>>{
        'unified:sources': <RegularVideoLinks>[
          RegularVideoLinks(
            url: 'https://provider.example/opaque?sig=1',
            quality: 'Auto',
            server: 'Jett',
            providerCode: 'unified:sources',
            isDash: true,
            availableHeights: <int>[1080, 720, 480, 360, 270, 180],
          ),
        ],
      },
      now: now,
    );

    expect(catalog.map((entry) => entry.qualityLabel), containsAll(<String>[
      'Auto', '1080p', '720p', '480p', '360p', '270p', '180p',
    ]));
    expect(catalog.where((entry) => entry.adaptiveTargetHeight != null),
        hasLength(6));
  });

  test('keeps equal resolutions from different providers as separate choices', () {
    final catalog = PlaybackQualityCatalog.collect(
      linksByProvider: <String, List<RegularVideoLinks>>{
        'jett': <RegularVideoLinks>[
          RegularVideoLinks(
            url: 'https://jett.example/movie.m3u8',
            quality: '1080p',
            server: 'Jett',
            providerCode: 'jett',
            isM3U8: true,
          ),
        ],
        'sova': <RegularVideoLinks>[
          RegularVideoLinks(
            url: 'https://sova.example/movie.mp4',
            quality: '1080p',
            server: 'Sova',
            providerCode: 'sova',
          ),
        ],
      },
      now: now,
    );

    expect(catalog, hasLength(2));
    expect(catalog.map((entry) => entry.link.server), containsAll(['Jett', 'Sova']));
  });

  test('includes real source-engine links stored under the unified bucket', () {
    final catalog = PlaybackQualityCatalog.collect(
      linksByProvider: <String, List<RegularVideoLinks>>{
        'unified:sources': <RegularVideoLinks>[
          RegularVideoLinks(
            url: 'https://jett.example/1080.mpd',
            quality: '1080p',
            server: 'Jett',
            providerCode: 'unified:sources',
            isDash: true,
          ),
          RegularVideoLinks(
            url: 'https://sova.example/720.m3u8',
            quality: '720p',
            server: 'Sova',
            providerCode: 'unified:sources',
            isM3U8: true,
          ),
        ],
      },
      now: now,
    );

    expect(catalog, hasLength(2));
    expect(catalog.map((entry) => entry.link.server), containsAll(['Jett', 'Sova']));
    expect(catalog.map((entry) => entry.link.url), containsAll([
      'https://jett.example/1080.mpd',
      'https://sova.example/720.m3u8',
    ]));
  });

  test('does not offer expired links in the quality picker', () {
    final catalog = PlaybackQualityCatalog.collect(
      linksByProvider: <String, List<RegularVideoLinks>>{
        'jett': <RegularVideoLinks>[
          RegularVideoLinks(
            url: 'https://jett.example/expired.mp4',
            quality: '1080p',
            server: 'Jett',
            providerCode: 'jett',
            expiresAt: now.subtract(const Duration(seconds: 1)),
          ),
          RegularVideoLinks(
            url: 'https://jett.example/valid.mp4',
            quality: '360p',
            server: 'Jett',
            providerCode: 'jett',
            expiresAt: now.add(const Duration(minutes: 5)),
          ),
        ],
      },
      now: now,
    );

    expect(catalog, hasLength(1));
    expect(catalog.single.link.url, 'https://jett.example/valid.mp4');
  });
}
