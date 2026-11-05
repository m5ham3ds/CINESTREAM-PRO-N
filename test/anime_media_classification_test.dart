import 'package:flixquest/models/movie.dart';
import 'package:flixquest/models/tv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes Japanese animation series from TMDB details', () {
    final details = TVDetails.fromJson(<String, dynamic>{
      'original_language': 'ja',
      'genres': <Map<String, dynamic>>[
        <String, dynamic>{'id': 16, 'name': 'Animation'},
        <String, dynamic>{'id': 10759, 'name': 'Action & Adventure'},
      ],
    });

    expect(details.isLikelyAnime, isTrue);
    expect(details.genreIds, contains(16));
  });

  test('does not classify non-Japanese animation as anime by genre alone', () {
    final details = TVDetails.fromJson(<String, dynamic>{
      'original_language': 'en',
      'genres': <Map<String, dynamic>>[
        <String, dynamic>{'id': 16, 'name': 'Animation'},
      ],
    });

    expect(details.isLikelyAnime, isFalse);
  });

  test('preserves explicit anime identification for feature films', () {
    final details = MovieDetails.fromJson(<String, dynamic>{
      'original_language': 'ja',
      'genres': <Map<String, dynamic>>[
        <String, dynamic>{'id': 16, 'name': 'Animation'},
      ],
    });

    expect(details.isLikelyAnime, isTrue);
    expect(details.genreIds, contains(16));
  });
}
