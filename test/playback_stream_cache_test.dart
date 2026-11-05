import 'package:flixquest/services/playback_stream_cache.dart';
import 'package:flixquest/video_providers/common.dart';
import 'package:flixquest/video_providers/unified/media_identity.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryPlaybackCacheVault implements PlaybackCacheVault {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

}

void main() {
  const identity = MediaIdentity(
    type: UnifiedMediaType.series,
    title: 'Cache Test Series',
    tmdbId: 123,
    seasonNumber: 2,
    episodeNumber: 4,
  );

  test('persists provider links, headers, subtitles and last working URL',
      () async {
    final vault = _MemoryPlaybackCacheVault();
    final cache = PlaybackStreamCacheStore(vault: vault);
    final headers = <String, String>{'Referer': 'https://example.com/'};
    final first = RegularVideoLinks(
      url: 'https://cdn.example.com/1080.m3u8',
      quality: '1080p',
      server: 'Provider A',
      providerCode: 'provider:a',
      isM3U8: true,
      headers: headers,
    );
    final second = RegularVideoLinks(
      url: 'https://cdn.example.com/720.mp4',
      quality: '720p',
      server: 'Provider B',
      providerCode: 'provider:b',
    );

    await cache.save(
      identity: identity,
      providers: <String, CachedProviderStreams>{
        'provider:a': CachedProviderStreams(
          providerCode: 'provider:a',
          providerName: 'Provider A',
          videoLinks: <RegularVideoLinks>[first],
          subtitleLinks: <RegularSubtitleLinks>[
            RegularSubtitleLinks(
              url: 'https://cdn.example.com/subtitles.vtt',
              language: 'English',
              headers: headers,
            ),
          ],
        ),
        'provider:b': CachedProviderStreams(
          providerCode: 'provider:b',
          providerName: 'Provider B',
          videoLinks: <RegularVideoLinks>[second],
        ),
      },
      lastProviderCode: 'provider:b',
      lastUrl: second.url,
    );

    final restored = await cache.read(identity);
    expect(restored?.lastProviderCode, 'provider:b');
    expect(restored?.lastUrl, second.url);
    expect(restored?.providers, hasLength(2));
    expect(
      restored!.providers['provider:a']!.videoLinks.single.headers,
      headers,
    );
    expect(
      restored.providers['provider:a']!.subtitleLinks.single.language,
      'English',
    );
  });

  test('invalidates one failed URL without deleting other qualities/providers',
      () async {
    final vault = _MemoryPlaybackCacheVault();
    final cache = PlaybackStreamCacheStore(vault: vault);
    await cache.save(
      identity: identity,
      providers: <String, CachedProviderStreams>{
        'provider:a': CachedProviderStreams(
          providerCode: 'provider:a',
          providerName: 'Provider A',
          videoLinks: <RegularVideoLinks>[
            RegularVideoLinks(
              url: 'https://cdn.example.com/a-1080.m3u8',
              quality: '1080p',
            ),
            RegularVideoLinks(
              url: 'https://cdn.example.com/a-720.m3u8',
              quality: '720p',
            ),
          ],
        ),
        'provider:b': CachedProviderStreams(
          providerCode: 'provider:b',
          providerName: 'Provider B',
          videoLinks: <RegularVideoLinks>[
            RegularVideoLinks(
              url: 'https://cdn.example.com/b-480.mp4',
              quality: '480p',
            ),
          ],
        ),
      },
      lastProviderCode: 'provider:a',
      lastUrl: 'https://cdn.example.com/a-1080.m3u8',
    );

    await cache.invalidateUrl(
      identity: identity,
      providerCode: 'provider:a',
      url: 'https://cdn.example.com/a-1080.m3u8',
    );

    final restored = await cache.read(identity);
    expect(restored, isNotNull);
    expect(restored!.providers['provider:a']!.videoLinks, hasLength(1));
    expect(
      restored.providers['provider:a']!.videoLinks.single.quality,
      '720p',
    );
    expect(restored.providers['provider:b']!.videoLinks, hasLength(1));
    expect(restored.lastUrl, 'https://cdn.example.com/a-720.m3u8');
  });
  test('adding a provider does not extend an older cached URL lifetime', () async {
    final vault = _MemoryPlaybackCacheVault();
    var now = DateTime.utc(2026, 11, 3, 10);
    final cache = PlaybackStreamCacheStore(
      vault: vault,
      clock: () => now,
      maxAge: const Duration(hours: 24),
    );
    const oldUrl = 'https://cdn.example.com/old-1080.m3u8';
    const newUrl = 'https://cdn.example.com/new-720.m3u8';

    await cache.save(
      identity: identity,
      providers: <String, CachedProviderStreams>{
        'provider:a': CachedProviderStreams(
          providerCode: 'provider:a',
          providerName: 'Provider A',
          videoLinks: <RegularVideoLinks>[
            RegularVideoLinks(url: oldUrl, quality: '1080p'),
          ],
        ),
      },
      lastProviderCode: 'provider:a',
      lastUrl: oldUrl,
    );

    now = now.add(const Duration(hours: 23));
    await cache.save(
      identity: identity,
      providers: <String, CachedProviderStreams>{
        'provider:a': CachedProviderStreams(
          providerCode: 'provider:a',
          providerName: 'Provider A',
          videoLinks: <RegularVideoLinks>[
            RegularVideoLinks(url: oldUrl, quality: '1080p'),
          ],
        ),
        'provider:b': CachedProviderStreams(
          providerCode: 'provider:b',
          providerName: 'Provider B',
          videoLinks: <RegularVideoLinks>[
            RegularVideoLinks(url: newUrl, quality: '720p'),
          ],
        ),
      },
      lastProviderCode: 'provider:b',
      lastUrl: newUrl,
    );

    now = now.add(const Duration(hours: 2));
    final restored = await cache.read(identity);
    expect(restored, isNotNull);
    expect(restored!.providers.containsKey('provider:a'), isFalse);
    expect(restored.providers['provider:b']!.videoLinks.single.url, newUrl);
  });

}
