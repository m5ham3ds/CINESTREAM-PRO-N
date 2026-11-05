import 'package:flixquest/video_providers/unified/media_identity.dart';
import 'package:flixquest/video_providers/unified/stream_option.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MediaIdentity', () {
    test('builds an IMDb Stremio episode id without losing season/episode', () {
      const media = MediaIdentity(
        type: UnifiedMediaType.series,
        title: 'Example Series',
        tmdbId: 42,
        seasonNumber: 2,
        episodeNumber: 7,
        externalIds: <String, String>{'imdb': 'tt1234567'},
      );

      expect(media.stremioType, 'series');
      expect(media.stremioId, 'tt1234567:2:7');
      expect(media.isEpisode, isTrue);
    });

    test('appends episode coordinates to namespaced source IDs', () {
      const media = MediaIdentity(
        type: UnifiedMediaType.anime,
        title: 'Example Anime',
        seasonNumber: 1,
        episodeNumber: 4,
        externalIds: <String, String>{'stremio': 'kitsu:12345'},
      );

      expect(media.stremioId, 'kitsu:12345:1:4');
    });

    test('does not guess an unsupported Stremio id from a TMDB integer', () {
      const media = MediaIdentity(
        type: UnifiedMediaType.movie,
        title: 'Example Movie',
        tmdbId: 42,
      );

      expect(media.stremioId, isNull);
    });
  });

  group('UnifiedStreamOption', () {
    test('round-trips headers, audio, nested subtitles and expiry metadata', () {
      final stream = UnifiedStreamOption(
        id: 'source-a::0',
        providerId: 'source-a',
        providerName: 'Source A',
        url: 'https://cdn.example/video.m3u8',
        quality: '1080p',
        container: StreamContainer.hls,
        headers: const <String, String>{'Referer': 'https://example.com/'},
        audioKind: StreamAudioKind.dub,
        audioLanguage: 'en',
        subtitles: const <UnifiedSubtitleTrack>[
          UnifiedSubtitleTrack(
            url: 'https://cdn.example/subs/ar.vtt',
            language: 'ar',
            format: 'vtt',
            isDefault: true,
          ),
        ],
        subtitleOffsetSeconds: 1.25,
        expiresAt: DateTime.utc(2026, 12, 1),
      );

      final restored = UnifiedStreamOption.fromJson(stream.toJson());
      expect(restored.url, stream.url);
      expect(restored.headers['Referer'], 'https://example.com/');
      expect(restored.audioKind, StreamAudioKind.dub);
      expect(restored.audioLanguage, 'en');
      expect(restored.subtitles.single.language, 'ar');
      expect(restored.subtitles.single.isDefault, isTrue);
      expect(restored.subtitleOffsetSeconds, 1.25);
      expect(restored.expiresAt, DateTime.utc(2026, 12, 1));
    });
  });
}
