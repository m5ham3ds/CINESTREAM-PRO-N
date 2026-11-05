import 'package:flixquest/video_providers/common.dart';
import 'package:flixquest/video_providers/unified/legacy_provider_adapter.dart';
import 'package:flixquest/video_providers/unified/source_repository_manager.dart';
import 'package:flixquest/video_providers/unified/source_manifest.dart';
import 'package:flixquest/video_providers/unified/source_engine.dart';
import 'package:flixquest/video_providers/unified/unified_source_service.dart';
import 'package:flixquest/video_providers/unified/stream_option.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preserves same-quality mirrors and request metadata from legacy source', () {
    final result = ProviderLoadResult(
      success: true,
      videoLinks: <RegularVideoLinks>[
        RegularVideoLinks(
          url: 'https://cdn-one.example/one.m3u8',
          quality: '1080p',
          server: 'Mirror One',
          isM3U8: true,
          isAdaptive: true,
          availableHeights: <int>[1080, 720, 480, 360],
          headers: <String, String>{'Referer': 'https://source.example/'},
        ),
        RegularVideoLinks(
          url: 'https://cdn-two.example/two.mp4',
          quality: '1080p',
          server: 'Mirror Two',
        ),
      ],
      subtitleLinks: <RegularSubtitleLinks>[
        RegularSubtitleLinks(
          url: 'https://cdn.example/ar.vtt',
          language: 'Arabic',
        ),
      ],
    );

    final unified = result.toUnifiedSourceResult(
      providerId: 'legacy:provider',
      providerName: 'Legacy Provider',
    );

    expect(unified.streams, hasLength(2));
    expect(unified.streams.map((item) => item.quality).toSet(), {'1080p'});
    expect(unified.streams.first.headers['Referer'],
        'https://source.example/');
    expect(unified.streams.first.container, StreamContainer.hls);
    expect(unified.streams.first.metadata['adaptiveMaster'], isTrue);
    expect(
      unified.streams.first.metadata['availableHeights'],
      <int>[1080, 720, 480, 360],
    );
    expect(unified.streams.last.container, StreamContainer.mp4);
    expect(unified.streams.first.subtitles.single.language, 'Arabic');
  });

  test('uses a unified stream height when the provider omits its quality label', () {
    final option = const UnifiedStreamOption(
      id: 'height-only',
      providerId: 'provider',
      providerName: 'Provider',
      url: 'https://cdn.example/stream.mp4',
      height: 540,
      quality: 'unknown quality',
      container: StreamContainer.mp4,
    );
    final adapted = UnifiedSourceSearchResult(
      repositorySnapshot: const SourceRepositorySyncResult(
        repositories: <SourceRepositoryManifest>[],
        sources: <SourceManifest>[],
        errors: <String, String>{},
      ),
      attempts: const <UnifiedSourceAttempt>[],
      streams: <UnifiedStreamOption>[option],
    ).toProviderLoadResult();

    expect(adapted.videoLinks, hasLength(1));
    expect(adapted.videoLinks!.single.quality, '540p');
  });

  test('only valid HTTP(S) non-expired streams reach the player adapter', () {
    final search = UnifiedSourceSearchResult(
      repositorySnapshot: const SourceRepositorySyncResult(
        repositories: <SourceRepositoryManifest>[],
        sources: <SourceManifest>[],
        errors: <String, String>{},
      ),
      attempts: const <UnifiedSourceAttempt>[],
      streams: <UnifiedStreamOption>[
        const UnifiedStreamOption(
          id: 'https',
          providerId: 'provider',
          providerName: 'HTTP Source',
          url: 'https://cdn.example/video.m3u8',
          quality: '1080p',
          container: StreamContainer.hls,
          headers: <String, String>{'Referer': 'https://source.example/'},
        ),
        const UnifiedStreamOption(
          id: 'file',
          providerId: 'provider',
          providerName: 'Local Source',
          url: 'file:///data/video.mp4',
          container: StreamContainer.mp4,
        ),
        UnifiedStreamOption(
          id: 'expired',
          providerId: 'provider',
          providerName: 'Expired Source',
          url: 'https://cdn.example/expired.m3u8',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
        const UnifiedStreamOption(
          id: 'unsupported',
          providerId: 'provider',
          providerName: 'Unsupported Source',
          url: 'https://cdn.example/unsupported',
          isPlayable: false,
        ),
      ],
    );

    final adapted = search.toProviderLoadResult();

    expect(adapted.success, isTrue);
    expect(adapted.videoLinks, hasLength(1));
    expect(adapted.videoLinks!.single.url, 'https://cdn.example/video.m3u8');
    expect(adapted.videoLinks!.single.headers, {'Referer': 'https://source.example/'});
    expect(adapted.videoLinks!.single.isM3U8, isTrue);
  });
}
