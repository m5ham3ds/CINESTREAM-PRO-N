import 'package:flixquest/video_providers/common.dart';
import 'package:flixquest/video_providers/unified/legacy_provider_adapter.dart';
import 'package:flixquest/video_providers/unified/source_engine.dart';
import 'package:flixquest/video_providers/unified/source_manifest.dart';
import 'package:flixquest/video_providers/unified/source_repository_manager.dart';
import 'package:flixquest/video_providers/unified/stream_option.dart';
import 'package:flixquest/video_providers/unified/unified_source_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UnifiedSearchResultLegacyAdapter', () {
    test('preserves server, quality, format, headers, and subtitles', () {
      final source = SourceManifest(
        id: 'vidking-sample',
        name: 'Vidking Sample',
        repositoryUrl: 'https://example.test/index.json',
        engine: const SourceEngineDescriptor(
          rawType: 'vidking-direct',
          kind: SourceEngineKind.vidkingDirect,
        ),
      );
      final stream = UnifiedStreamOption(
        id: 'vidking-sample:movie:42',
        providerId: source.id,
        providerName: source.name,
        url: 'https://cdn.example.test/movie/master.m3u8',
        quality: '1080p',
        container: StreamContainer.hls,
        headers: const {
          'Referer': 'https://vidking.example/',
          'User-Agent': 'CineStream test agent',
        },
        subtitles: const [
          UnifiedSubtitleTrack(
            url: 'https://cdn.example.test/subtitles/ar.vtt',
            language: 'ar',
            label: 'Arabic',
            headers: {'Referer': 'https://vidking.example/'},
          ),
        ],
      );
      final snapshot = SourceRepositorySyncResult(
        repositories: const [
          SourceRepositoryManifest(
            url: 'https://example.test/index.json',
            name: 'Example repository',
          ),
        ],
        sources: [source],
        catalog: [source],
        errors: const {},
      );
      final result = UnifiedSourceSearchResult(
        repositorySnapshot: snapshot,
        attempts: [
          UnifiedSourceAttempt(
            source: source,
            result: UnifiedSourceResult(streams: [stream]),
          ),
        ],
        streams: [stream],
      ).toProviderLoadResult();

      expect(result.success, isTrue);
      expect(result.videoLinks, hasLength(1));
      final link = result.videoLinks!.single;
      expect(link.url, stream.url);
      expect(link.server, source.name);
      expect(link.quality, contains('1080p'));
      expect(link.quality, contains(source.name));
      expect(link.isM3U8, isTrue);
      expect(link.isDash, isFalse);
      expect(link.headers, stream.headers);
      expect(result.subtitleLinks, hasLength(1));
      expect(result.subtitleLinks!.single.url,
          'https://cdn.example.test/subtitles/ar.vtt');
      expect(result.subtitleLinks!.single.language, 'Arabic');
      expect(result.subtitleLinks!.single.headers, {
        'Referer': 'https://vidking.example/',
      });
    });

    test('omits expired and explicitly unplayable stream results', () {
      final source = SourceManifest(
        id: 'sample',
        name: 'Sample',
        engine: const SourceEngineDescriptor(
          rawType: 'stremio',
          kind: SourceEngineKind.stremio,
        ),
      );
      final expired = UnifiedStreamOption(
        id: 'expired',
        providerId: source.id,
        providerName: source.name,
        url: 'https://cdn.example.test/expired.m3u8',
        expiresAt: DateTime.utc(2020),
      );
      final unplayable = UnifiedStreamOption(
        id: 'unplayable',
        providerId: source.id,
        providerName: source.name,
        url: 'https://cdn.example.test/unplayable.mp4',
        isPlayable: false,
      );
      final result = UnifiedSourceSearchResult(
        repositorySnapshot: const SourceRepositorySyncResult(
          repositories: [],
          sources: [],
          errors: {},
        ),
        attempts: [
          UnifiedSourceAttempt(
            source: source,
            result: UnifiedSourceResult(streams: [expired, unplayable]),
          ),
        ],
        streams: [expired, unplayable],
      ).toProviderLoadResult();

      expect(result.success, isFalse);
      expect(result.videoLinks, isEmpty);
      expect(result.errorMessage, contains('No playable streams'));
    });
  });
}
