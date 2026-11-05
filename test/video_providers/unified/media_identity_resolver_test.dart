import 'dart:async';

import 'package:flixquest/video_providers/unified/media_identity.dart';
import 'package:flixquest/video_providers/unified/media_identity_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MediaIdentityResolver', () {
    test('enriches a movie with a valid IMDb identifier', () async {
      var lookups = 0;
      final resolver = MediaIdentityResolver(
        lookup: (type, tmdbId) async {
          lookups++;
          expect(type, UnifiedMediaType.movie);
          expect(tmdbId, 157336);
          return 'tt1375666';
        },
      );
      const identity = MediaIdentity(
        type: UnifiedMediaType.movie,
        title: 'Inception',
        year: 2010,
        tmdbId: 157336,
      );

      final resolved = await resolver.enrich(identity);

      expect(resolved.imdbId, 'tt1375666');
      expect(resolved.externalIds['imdb'], 'tt1375666');
      expect(resolved.title, identity.title);
      expect(resolved.tmdbId, identity.tmdbId);
      expect(identity.imdbId, isNull, reason: 'The original identity is immutable.');
      expect(lookups, 1);
    });

    test('keeps movie and TV external-ID mappings separate for equal TMDB IDs', () async {
      final received = <UnifiedMediaType>[];
      final resolver = MediaIdentityResolver(
        lookup: (type, _) async {
          received.add(type);
          return type == UnifiedMediaType.movie ? 'tt1111111' : 'tt2222222';
        },
      );
      const movie = MediaIdentity(
        type: UnifiedMediaType.movie,
        title: 'Same numeric ID, movie',
        tmdbId: 42,
      );
      const series = MediaIdentity(
        type: UnifiedMediaType.series,
        title: 'Same numeric ID, series',
        tmdbId: 42,
        seasonNumber: 1,
        episodeNumber: 1,
      );

      final resolvedMovie = await resolver.enrich(movie);
      final resolvedSeries = await resolver.enrich(series);

      expect(resolvedMovie.imdbId, 'tt1111111');
      expect(resolvedSeries.imdbId, 'tt2222222');
      expect(received, <UnifiedMediaType>[
        UnifiedMediaType.movie,
        UnifiedMediaType.series,
      ]);
    });

    test('uses the TV lookup for both series and anime episodes', () async {
      final received = <UnifiedMediaType>[];
      final resolver = MediaIdentityResolver(
        lookup: (type, _) async {
          received.add(type);
          return 'tt1234567';
        },
      );

      final series = await resolver.enrich(const MediaIdentity(
        type: UnifiedMediaType.series,
        title: 'Criminal Minds',
        tmdbId: 4057,
        seasonNumber: 1,
        episodeNumber: 1,
      ));
      final anime = await resolver.enrich(const MediaIdentity(
        type: UnifiedMediaType.anime,
        title: 'One Piece',
        tmdbId: 37854,
        seasonNumber: 1,
        episodeNumber: 1,
      ));

      expect(series.imdbId, 'tt1234567');
      expect(anime.imdbId, 'tt1234567');
      expect(received, <UnifiedMediaType>[
        UnifiedMediaType.series,
        UnifiedMediaType.anime,
      ]);
    });

    test('preserves other external IDs and an existing IMDb ID', () async {
      var lookups = 0;
      final resolver = MediaIdentityResolver(
        lookup: (_, __) async {
          lookups++;
          return 'tt9999999';
        },
      );
      const identity = MediaIdentity(
        type: UnifiedMediaType.series,
        title: 'Example series',
        tmdbId: 100,
        seasonNumber: 2,
        episodeNumber: 3,
        externalIds: <String, String>{
          'imdb': 'tt1111111',
          'anilist': '21',
        },
      );

      final resolved = await resolver.enrich(identity);

      expect(resolved.imdbId, 'tt1111111');
      expect(resolved.externalIds['anilist'], '21');
      expect(lookups, 0);
    });

    test('does not treat a malformed pre-existing IMDb value as valid', () async {
      var lookups = 0;
      final resolver = MediaIdentityResolver(
        lookup: (_, __) async {
          lookups++;
          return 'tt7654321';
        },
      );
      const identity = MediaIdentity(
        type: UnifiedMediaType.movie,
        title: 'Malformed existing external ID',
        tmdbId: 321,
        externalIds: <String, String>{'imdb': 'tt-not-valid'},
      );

      final resolved = await resolver.enrich(identity);

      expect(resolved.imdbId, 'tt7654321');
      expect(lookups, 1);
    });

    test('does not look up missing or invalid TMDB IDs', () async {
      var lookups = 0;
      final resolver = MediaIdentityResolver(
        lookup: (_, __) async {
          lookups++;
          return 'tt1234567';
        },
      );

      final missing = await resolver.enrich(const MediaIdentity(
        type: UnifiedMediaType.movie,
        title: 'No TMDB ID',
      ));
      final invalid = await resolver.enrich(const MediaIdentity(
        type: UnifiedMediaType.movie,
        title: 'Invalid TMDB ID',
        tmdbId: 0,
      ));

      expect(missing.imdbId, isNull);
      expect(invalid.imdbId, isNull);
      expect(lookups, 0);
    });

    test('coalesces concurrent lookups for the same media', () async {
      final response = Completer<String?>();
      var lookups = 0;
      final resolver = MediaIdentityResolver(
        lookup: (_, __) {
          lookups++;
          return response.future;
        },
      );
      const identity = MediaIdentity(
        type: UnifiedMediaType.movie,
        title: 'The Matrix',
        tmdbId: 603,
      );

      final first = resolver.enrich(identity);
      final second = resolver.enrich(identity);
      await Future<void>.delayed(Duration.zero);
      expect(lookups, 1);
      response.complete('tt0133093');

      expect((await first).imdbId, 'tt0133093');
      expect((await second).imdbId, 'tt0133093');
      expect(lookups, 1);
    });

    test('refreshes the in-memory mapping after the 30-day TTL', () async {
      var now = DateTime.utc(2026, 1, 1);
      var lookups = 0;
      final resolver = MediaIdentityResolver(
        clock: () => now,
        lookup: (_, __) async {
          lookups++;
          return lookups == 1 ? 'tt0133093' : 'tt0232500';
        },
      );
      const identity = MediaIdentity(
        type: UnifiedMediaType.movie,
        title: 'Example',
        tmdbId: 603,
      );

      expect((await resolver.enrich(identity)).imdbId, 'tt0133093');
      now = now.add(const Duration(days: 29));
      expect((await resolver.enrich(identity)).imdbId, 'tt0133093');
      expect(lookups, 1);

      now = now.add(const Duration(days: 2));
      expect((await resolver.enrich(identity)).imdbId, 'tt0232500');
      expect(lookups, 2);
    });

    test('ignores malformed IMDb values returned by the lookup', () async {
      final resolver = MediaIdentityResolver(
        lookup: (_, __) async => 'imdb:1234',
      );
      final resolved = await resolver.enrich(const MediaIdentity(
        type: UnifiedMediaType.movie,
        title: 'Malformed response',
        tmdbId: 1,
      ));
      expect(resolved.imdbId, isNull);
    });
  });
}
