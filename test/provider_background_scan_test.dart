import 'dart:async';

import 'package:flixquest/functions/video_utils.dart';
import 'package:flixquest/video_providers/common.dart';
import 'package:flixquest/video_providers/names.dart';
import 'package:flixquest/video_providers/provider_loader.dart';
import 'package:flixquest/video_providers/unified/media_identity.dart';
import 'package:flixquest/video_providers/unified/source_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderLoadResult _links(String quality) => ProviderLoadResult(
      success: true,
      videoLinks: <RegularVideoLinks>[
        RegularVideoLinks(
          url: 'https://example.com/$quality.m3u8',
          quality: quality,
        ),
      ],
    );

void main() {
  final movieIdentity = const MediaIdentity(
    type: UnifiedMediaType.movie,
    title: 'Background Scan Test',
  );

  test('returns first playable provider while bounded scan continues', () async {
    final providers = List<VideoProvider>.generate(
      3,
      (index) => VideoProvider.scraper(
        id: '$index',
        name: 'Provider $index',
      ),
    );
    final requests = <String, Completer<ProviderLoadResult>>{
      for (final provider in providers)
        provider.apiId!: Completer<ProviderLoadResult>(),
    };
    final started = <String>[];
    final session = ProviderLoader.startScan(
      providers: providers,
      unifiedMediaIdentity: movieIdentity,
      maxConcurrency: 2,
      load: (provider) {
        started.add(provider.apiId!);
        return requests[provider.apiId]!.future;
      },
    );

    await Future<void>.delayed(Duration.zero);
    expect(started, containsAll(<String>['0', '1']));
    expect(started, hasLength(2));

    requests['0']!.complete(_links('1080p'));
    final first = await session.firstPlayable;
    expect(first?.provider, providers.first);
    expect(first?.scanSession, same(session));

    // The first stream has already been handed back, but the scan remains live.
    expect(session.isCompleted, isFalse);
    requests['1']!.complete(_links('720p'));
    await Future<void>.delayed(Duration.zero);
    requests['2']!.complete(_links('480p'));
    await session.completed;

    expect(session.qualityTargetReached, isTrue);
    expect(session.isCompleted, isTrue);
  });

  test('stops scheduling new sources once 480p 720p and 1080p are found',
      () async {
    final providers = List<VideoProvider>.generate(
      4,
      (index) => VideoProvider.scraper(
        id: '$index',
        name: 'Provider $index',
      ),
    );
    final started = <String>[];
    final session = ProviderLoader.startScan(
      providers: providers,
      unifiedMediaIdentity: movieIdentity,
      maxConcurrency: 1,
      load: (provider) async {
        started.add(provider.apiId!);
        switch (provider.apiId) {
          case '0':
            return _links('1080p');
          case '1':
            return _links('720p');
          default:
            return _links('480p');
        }
      },
    );

    await session.firstPlayable;
    await session.completed;
    expect(started, <String>['0', '1', '2']);
    expect(session.qualityTargetReached, isTrue);
  });

  test(
    'collects every returned quality while filling the three-height target',
    () async {
      final providers = <VideoProvider>[
        VideoProvider.scraper(id: '1080-provider', name: '1080 Provider'),
        VideoProvider.scraper(id: '720-provider', name: '720 Provider'),
        VideoProvider.scraper(id: '480-provider', name: '480 Provider'),
        VideoProvider.scraper(id: 'must-not-start', name: 'Must Not Start'),
      ];
      final started = <String>[];
      final received = <String, List<String>>{};
      final responses = <String, List<String>>{
        '1080-provider': <String>['1080p', '360p', '270p'],
        '720-provider': <String>['720p', '180p'],
        '480-provider': <String>['480p', '1440p'],
      };
      final session = ProviderLoader.startScan(
        providers: providers,
        unifiedMediaIdentity: movieIdentity,
        maxConcurrency: 1,
        onResult: (_, provider, result) {
          received[provider.apiId!] = (result.videoLinks ?? const [])
              .map((link) => link.quality ?? '')
              .toList(growable: false);
        },
        load: (provider) async {
          final code = provider.apiId!;
          started.add(code);
          return ProviderLoadResult(
            success: true,
            videoLinks: <RegularVideoLinks>[
              for (final quality in responses[code]!)
                RegularVideoLinks(
                  url: 'https://example.com/$code-$quality.m3u8',
                  quality: quality,
                ),
            ],
          );
        },
      );

      await session.firstPlayable;
      await session.completed;

      expect(started, <String>['1080-provider', '720-provider', '480-provider']);
      expect(session.qualityTargetReached, isTrue);
      expect(received['1080-provider'], <String>['1080p', '360p', '270p']);
      expect(received['720-provider'], <String>['720p', '180p']);
      expect(received['480-provider'], <String>['480p', '1440p']);
      expect(received.containsKey('must-not-start'), isFalse);
    },
  );

  test(
    'sub-480 and above-1080 qualities are retained but do not replace target heights',
    () async {
      final provider = VideoProvider.scraper(
        id: 'odd-resolutions',
        name: 'Odd Resolutions',
      );
      final receivedQualities = <String>[];
      final session = ProviderLoader.startScan(
        providers: <VideoProvider>[provider],
        unifiedMediaIdentity: movieIdentity,
        maxConcurrency: 1,
        onResult: (_, __, result) {
          receivedQualities.addAll(
            (result.videoLinks ?? const <RegularVideoLinks>[])
                .map((link) => link.quality ?? ''),
          );
        },
        load: (_) async => ProviderLoadResult(
          success: true,
          videoLinks: <RegularVideoLinks>[
            RegularVideoLinks(
              url: 'https://example.com/2160.m3u8',
              quality: '2160p',
            ),
            RegularVideoLinks(
              url: 'https://example.com/360.m3u8',
              quality: '360p',
            ),
            RegularVideoLinks(
              url: 'https://example.com/270.m3u8',
              quality: '270',
            ),
            RegularVideoLinks(
              url: 'https://example.com/180.m3u8',
              quality: '180',
            ),
          ],
        ),
      );

      await session.firstPlayable;
      await session.completed;
      expect(session.qualityTargetReached, isFalse);
      expect(receivedQualities, <String>['2160p', '360p', '270', '180']);
    },
  );

  test('exposes results that completed before the player subscribes', () async {
    final fast = VideoProvider.scraper(id: 'fast-snapshot', name: 'Fast Snapshot');
    final session = ProviderLoader.startScan(
      providers: <VideoProvider>[fast],
      unifiedMediaIdentity: movieIdentity,
      maxConcurrency: 1,
      load: (_) async => _links('1080p'),
    );

    await session.completed;
    expect(session.resolvedResults.keys, contains(fast.codeName));
    expect(session.resolvedResults[fast.codeName]?.videoLinks?.single.quality,
        '1080p');
  });

  test('adaptive manifest discoveries can complete the quality target after provider scan ends',
      () async {
    final provider = VideoProvider.scraper(
      id: 'adaptive-master',
      name: 'Adaptive Master',
    );
    final session = ProviderLoader.startScan(
      providers: <VideoProvider>[provider],
      unifiedMediaIdentity: movieIdentity,
      maxConcurrency: 1,
      load: (_) async => ProviderLoadResult(
        success: true,
        videoLinks: <RegularVideoLinks>[
          RegularVideoLinks(
            url: 'https://example.com/master',
            quality: 'Auto',
            isAdaptive: true,
          ),
        ],
      ),
    );

    await session.firstPlayable;
    await session.completed;
    expect(session.qualityTargetReached, isFalse);

    session.reportAdaptiveQualityHeights(<int>[1080, 720, 480, 360, 270, 180]);

    expect(session.qualityTargetReached, isTrue);
    expect(session.availableQualityHeights,
        containsAll(<int>[1080, 720, 480, 360, 270, 180]));
  });

  test('does not invoke anime-exclusive sources for ordinary movies', () async {
    final animeOnly = VideoProvider.unifiedSource(const SourceManifest(
      id: 'anime-only',
      name: 'Anime Only',
      tags: <String>['anime'],
      engine: SourceEngineDescriptor(
        rawType: 'anikoto',
        kind: SourceEngineKind.animeSite,
      ),
    ));
    final universal = VideoProvider.scraper(
      id: 'universal',
      name: 'Universal',
    );
    final started = <String>[];
    final session = ProviderLoader.startScan(
      providers: <VideoProvider>[animeOnly, universal],
      unifiedMediaIdentity: movieIdentity,
      maxConcurrency: 1,
      load: (provider) async {
        started.add(provider.codeName);
        return _links('720p');
      },
    );

    final first = await session.firstPlayable;
    await session.completed;
    expect(started, <String>[universal.codeName]);
    expect(first?.provider, universal);
  });
  test('defers Web Embed fallbacks until direct providers finish or head start expires', () async {
    final direct = VideoProvider.scraper(id: 'direct', name: 'Direct');
    final fallback = VideoProvider.unifiedSource(const SourceManifest(
      id: 'web-fallback',
      name: 'Web fallback',
      isFallback: true,
      tags: <String>['movies', 'series', 'fallback'],
      engine: SourceEngineDescriptor(
        rawType: 'web-embed',
        kind: SourceEngineKind.webEmbed,
      ),
    ));
    final directResult = Completer<ProviderLoadResult>();
    final started = <String>[];
    final session = ProviderLoader.startScan(
      providers: <VideoProvider>[direct, fallback],
      unifiedMediaIdentity: movieIdentity,
      maxConcurrency: 2,
      fallbackHeadStart: const Duration(milliseconds: 20),
      load: (provider) {
        started.add(provider.codeName);
        if (provider == direct) return directResult.future;
        return Future<ProviderLoadResult>.value(_links('720p'));
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(started, <String>[direct.codeName]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(started, contains(fallback.codeName));
    directResult.complete(_links('1080p'));
    await session.completed;
  });

  test('keeps every quality from completed and already in-flight providers', () async {
    final providers = List<VideoProvider>.generate(
      3,
      (index) => VideoProvider.scraper(
        id: 'quality-$index',
        name: 'Quality Provider $index',
      ),
    );
    final lateResult = Completer<ProviderLoadResult>();
    final started = <String>[];
    final received = <String, List<String>>{};
    final session = ProviderLoader.startScan(
      providers: providers,
      unifiedMediaIdentity: movieIdentity,
      maxConcurrency: 2,
      onResult: (_, provider, result) {
        received[provider.apiId!] = (result.videoLinks ?? const [])
            .map((link) => link.quality ?? '')
            .toList(growable: false);
      },
      load: (provider) {
        started.add(provider.apiId!);
        if (provider.apiId == 'quality-0') {
          return Future<ProviderLoadResult>.value(ProviderLoadResult(
            success: true,
            videoLinks: <RegularVideoLinks>[
              RegularVideoLinks(
                url: 'https://example.com/1440.m3u8', quality: '1440p'),
              RegularVideoLinks(
                url: 'https://example.com/1080.m3u8', quality: '1080p'),
              RegularVideoLinks(
                url: 'https://example.com/720.m3u8', quality: '720p'),
              RegularVideoLinks(
                url: 'https://example.com/480.m3u8', quality: '480p'),
              RegularVideoLinks(
                url: 'https://example.com/360.m3u8', quality: '360p'),
              RegularVideoLinks(
                url: 'https://example.com/270.m3u8', quality: '270p'),
              RegularVideoLinks(
                url: 'https://example.com/180.m3u8', quality: '180p'),
            ],
          ));
        }
        if (provider.apiId == 'quality-1') return lateResult.future;
        return Future<ProviderLoadResult>.value(_links('240p'));
      },
    );

    await session.firstPlayable;
    expect(session.qualityTargetReached, isTrue);
    expect(session.inFlightProviderCount, 1);
    // The second request was already in flight when the three stopping
    // heights arrived. It must still be collected in full.
    lateResult.complete(ProviderLoadResult(
      success: true,
      videoLinks: <RegularVideoLinks>[
        RegularVideoLinks(
          url: 'https://example.com/270-late.m3u8', quality: '270p'),
        RegularVideoLinks(
          url: 'https://example.com/180-late.m3u8', quality: '180p'),
      ],
    ));
    await session.completed;

    expect(session.inFlightProviderCount, 0);
    expect(started, <String>['quality-0', 'quality-1']);
    expect(received['quality-0'], <String>[
      '1440p', '1080p', '720p', '480p', '360p', '270p', '180p',
    ]);
    expect(received['quality-1'], <String>['270p', '180p']);
    expect(received.containsKey('quality-2'), isFalse);
  });

  test('restored qualities seed the target and only missing providers are scanned',
      () async {
    final missing = <VideoProvider>[
      VideoProvider.scraper(id: 'missing-720', name: 'Missing 720'),
      VideoProvider.scraper(id: 'missing-480', name: 'Missing 480'),
      VideoProvider.scraper(id: 'must-not-run', name: 'Must Not Run'),
    ];
    final restored = ProviderLoadResult(
      success: true,
      videoLinks: <RegularVideoLinks>[
        RegularVideoLinks(
          url: 'https://example.com/saved-1080.m3u8', quality: '1080p'),
        RegularVideoLinks(
          url: 'https://example.com/saved-360.m3u8', quality: '360p'),
        RegularVideoLinks(
          url: 'https://example.com/saved-270.m3u8', quality: '270p'),
      ],
    );
    final started = <String>[];
    final session = ProviderLoader.startScan(
      providers: missing,
      initialResults: <String, ProviderLoadResult>{'cached-provider': restored},
      unifiedMediaIdentity: movieIdentity,
      maxConcurrency: 1,
      load: (provider) async {
        started.add(provider.apiId!);
        if (provider.apiId == 'missing-720') {
          return ProviderLoadResult(
            success: true,
            videoLinks: <RegularVideoLinks>[
              RegularVideoLinks(
                url: 'https://example.com/720.m3u8', quality: '720p'),
              RegularVideoLinks(
                url: 'https://example.com/180.m3u8', quality: '180p'),
            ],
          );
        }
        return ProviderLoadResult(
          success: true,
          videoLinks: <RegularVideoLinks>[
            RegularVideoLinks(
              url: 'https://example.com/480.m3u8', quality: '480p'),
              RegularVideoLinks(
                url: 'https://example.com/270.m3u8', quality: '270p'),
            ],
          ],
        );
      },
    );

    await session.firstPlayable;
    await session.completed;
    expect(started, <String>['missing-720', 'missing-480']);
    expect(session.qualityTargetReached, isTrue);
  });

  test('does not scan more providers when restored cache already has target qualities',
      () async {
    final provider = VideoProvider.scraper(id: 'unneeded', name: 'Unneeded');
    final started = <String>[];
    final session = ProviderLoader.startScan(
      providers: <VideoProvider>[provider],
      initialResults: <String, ProviderLoadResult>{
        'cached': ProviderLoadResult(
          success: true,
          videoLinks: <RegularVideoLinks>[
            RegularVideoLinks(
              url: 'https://example.com/1080.m3u8', quality: '1080p'),
            RegularVideoLinks(
              url: 'https://example.com/720.m3u8', quality: '720p'),
            RegularVideoLinks(
              url: 'https://example.com/480.m3u8', quality: '480p'),
          ],
        ),
      },
      unifiedMediaIdentity: movieIdentity,
      load: (source) async {
        started.add(source.apiId!);
        return _links('360p');
      },
    );

    await session.completed;
    expect(session.qualityTargetReached, isTrue);
    expect(started, isEmpty);
  });

  test('quality map keeps duplicate resolutions from different providers', () {
    final links = <RegularVideoLinks>[
      RegularVideoLinks(
        url: 'https://example.com/sova-480.m3u8',
        quality: '480p',
        server: 'Sova',
      ),
      RegularVideoLinks(
        url: 'https://example.com/jett-480.m3u8',
        quality: '480p',
        server: 'Jett',
      ),
      RegularVideoLinks(
        url: 'https://example.com/jett-360.m3u8',
        quality: '360p',
        server: 'Jett',
      ),
      RegularVideoLinks(
        url: 'https://example.com/jett-270.m3u8',
        quality: '270',
        server: 'Jett',
      ),
    ];

    final sources = VideoUtils.convertVideoLinksToMap(links);
    expect(sources, hasLength(4));
    expect(sources.values, containsAll(<String>[
      'https://example.com/sova-480.m3u8',
      'https://example.com/jett-480.m3u8',
      'https://example.com/jett-360.m3u8',
      'https://example.com/jett-270.m3u8',
    ]));
    expect(sources.keys, contains('480p · Sova'));
    expect(sources.keys, contains('480p · Jett'));
    expect(VideoUtils.videoQualityHeight('270'), 270);
  });

}
