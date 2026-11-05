import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flixquest/models/external_subtitles.dart';
import 'package:flixquest/services/external_subtitle_service.dart';
import 'package:flixquest/video_providers/unified/media_identity.dart';
import 'package:flixquest/video_providers/unified/media_identity_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUpAll(() {
    dotenv.testLoad(fileInput: 'OPENSUBTITLES_API_KEY=\nSUBDL_API_KEY=\nARABICSUBS_PROXY_URL=');
  });

  group('ExternalSubtitleService', () {
    test('searches OpenSubtitles using the IMDb id mapped from TMDB', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.host == 'rest.opensubtitles.org') {
          return http.Response(
            jsonEncode(<Map<String, dynamic>>[
              <String, dynamic>{
                'IDSubtitleFile': '8123',
                'SubDownloadLink': 'https://dl.opensubtitles.org/sub/8123.gz',
                'SubFormat': 'srt',
                'LanguageName': 'English',
                'ISO639': 'en',
                'SubHearingImpaired': '0',
                'SubDownloadsCnt': '50',
                'MovieReleaseName': 'Example.Release',
              },
            ]),
          );
        }
        if (request.url.host == 'api.subsource.net') {
          return http.Response(jsonEncode({'results': []}), 200);
        }
        return http.Response('not found', 404);
      });
      final resolver = MediaIdentityResolver(
        lookup: (UnifiedMediaType type, int tmdbId) async => 'tt1234567',
      );
      final service = ExternalSubtitleService(
        '',
        client: client,
        identityResolver: resolver,
      );

      final results = await service.fetchMovieSubtitles(
        42,
        title: 'Example movie',
        year: 2025,
        preferredLanguageCode: 'ar',
      );

      expect(results, hasLength(1));
      expect(results.single.source, 'OpenSubtitles');
      expect(results.single.id, 'opensubtitles_8123');
      expect(results.single.language, 'en');
      expect(
        requests.where((request) => request.url.host == 'rest.opensubtitles.org'),
        hasLength(3),
      );
      expect(
        requests.any((request) => request.url.path.contains('/sublanguageid-ara')),
        isTrue,
      );
      final legacyRequest = requests.firstWhere(
        (request) => request.url.host == 'rest.opensubtitles.org',
      );
      expect(legacyRequest.headers['user-agent'], 'TemporaryUserAgent');
    });

    test('uses OpenSubtitles v1 Arabic search and downloads its temporary link', () async {
      const arabicSrt = '1\n00:00:01,000 --> 00:00:02,000\nمرحبا\n';
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.host == 'api.opensubtitles.com' &&
            request.method == 'GET' && request.url.path.endsWith('/subtitles')) {
          expect(request.headers['api-key'], 'test-open-key');
          expect(request.url.queryParameters['languages'], 'ar,en');
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'attributes': {
                    'language': 'ara',
                    'hearing_impaired': false,
                    'release': 'Example.Arabic.Release',
                    'files': [
                      {'file_id': 4567, 'file_name': 'arabic.srt'}
                    ],
                  }
                }
              ]
            }),
            200,
          );
        }
        if (request.url.host == 'api.subsource.net' &&
            request.url.path.endsWith('/movie/search')) {
          return http.Response(jsonEncode({'results': []}), 200);
        }
        if (request.url.host == 'api.opensubtitles.com' &&
            request.method == 'POST' && request.url.path.endsWith('/download')) {
          expect(request.headers['api-key'], 'test-open-key');
          expect(jsonDecode(request.body)['file_id'], 4567);
          return http.Response(
            jsonEncode({'link': 'https://download.example.test/arabic.srt'}),
            200,
          );
        }
        if (request.url.host == 'download.example.test') {
          return http.Response(arabicSrt, 200);
        }
        return http.Response('not found', 404);
      });
      final resolver = MediaIdentityResolver(
        lookup: (UnifiedMediaType type, int tmdbId) async => 'tt1234567',
      );
      final service = ExternalSubtitleService(
        '',
        client: client,
        identityResolver: resolver,
        openSubtitlesApiKey: 'test-open-key',
      );

      final results = await service.fetchMovieSubtitles(
        42,
        title: 'Example movie',
        year: 2025,
        preferredLanguageCode: 'ar',
      );
      expect(results, hasLength(1));
      expect(results.single.language, 'ar');
      expect(results.single.url, 'opensubtitles-v1://file/4567');

      final vtt = await service.downloadAndNormalizeForPlayback(results.single);
      expect(vtt, contains('WEBVTT'));
      expect(vtt, contains('مرحبا'));
      expect(requests.where((request) => request.url.host == 'api.opensubtitles.com'),
          hasLength(2));
    });

    test('searches SubSource by season and filters to the exact episode', () async {
      final requestedUrls = <Uri>[];
      final client = MockClient((request) async {
        requestedUrls.add(request.url);
        if (request.url.host == 'rest.opensubtitles.org') {
          return http.Response('[]', 200);
        }
        if (request.method == 'POST' && request.url.path.endsWith('/movie/search')) {
          return http.Response(
            jsonEncode({'results': [{'link': '/series/example-show'}]}),
            200,
          );
        }
        if (request.url.host == 'api.subsource.net' &&
            request.url.path.endsWith('/season-1')) {
          return http.Response(
            jsonEncode({
              'subtitles': [
                {
                  'id': 10,
                  'language': 'english',
                  'release_type': 'episode',
                  'release_info': 'Example.Show.S01E02.1080p',
                  'hearing_impaired': 0,
                  'link': 'detail-10',
                },
                {
                  'id': 11,
                  'language': 'english',
                  'release_type': 'episode',
                  'release_info': 'Example.Show.S01E03.1080p',
                  'hearing_impaired': 0,
                  'link': 'detail-11',
                },
                {
                  'id': 12,
                  'language': 'french',
                  'release_type': 'episode',
                  'release_info': 'Example.Show.S01E02.1080p',
                  'hearing_impaired': 0,
                  'link': 'detail-12',
                },
              ],
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      final resolver = MediaIdentityResolver(
        lookup: (UnifiedMediaType type, int tmdbId) async => 'tt1234567',
      );
      final service = ExternalSubtitleService(
        '',
        client: client,
        identityResolver: resolver,
      );

      final results = await service.fetchTVSubtitles(
        99,
        1,
        2,
        title: 'Example Show',
        preferredLanguageCode: 'en',
      );

      expect(results, hasLength(1));
      expect(results.single.source, 'SubSource');
      expect(results.single.id, 'subsource_10');
      expect(results.single.url, 'https://api.subsource.net/v1/subtitle/detail-10');
      expect(
        requestedUrls.any((uri) => uri.path.endsWith('/subtitles/example-show/season-1')),
        isTrue,
      );
    });

    test('resolves a SubSource token and normalizes the returned ZIP', () async {
      const srt = '1\n00:00:01,000 --> 00:00:02,000\nTokenized subtitle\n';
      final archive = Archive()
        ..addFile(ArchiveFile(
          'track.srt',
          utf8.encode(srt).length,
          Uint8List.fromList(utf8.encode(srt)),
        ));
      final zipBytes = ZipEncoder().encodeBytes(archive);
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);
        if (request.url.path.endsWith('/subtitle/detail-20')) {
          return http.Response(
            jsonEncode({'subtitle': {'download_token': 'short-lived-token'}}),
            200,
          );
        }
        if (request.url.path.endsWith('/subtitle/download/short-lived-token')) {
          return http.Response.bytes(zipBytes, 200);
        }
        return http.Response('not found', 404);
      });
      final service = ExternalSubtitleService('', client: client);
      final source = await service.convertToBetterPlayerSource(
        ExternalSubtitle(
          id: 'subsource_20',
          url: 'https://api.subsource.net/v1/subtitle/detail-20',
          flagUrl: '',
          format: 'auto',
          encoding: 'zip/auto',
          display: 'English',
          language: 'en',
          media: 'movie',
          isHearingImpaired: false,
          release: 'Example.Release',
          source: 'SubSource',
        ),
      );

      expect(source.content, contains('WEBVTT'));
      expect(source.content, contains('Tokenized subtitle'));
      expect(requested, hasLength(2));
      expect(requested.last.path, endsWith('/subtitle/download/short-lived-token'));
    });

    test('decompresses an OpenSubtitles gzip download with its required user agent', () async {
      const srt = '1\n00:00:01,000 --> 00:00:02,000\nOpenSubtitles cue\n';
      final compressed = gzip.encode(utf8.encode(srt));
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response.bytes(compressed, 200);
      });
      final service = ExternalSubtitleService('', client: client);
      final source = await service.convertToBetterPlayerSource(
        ExternalSubtitle(
          id: 'opensubtitles_44',
          url: 'https://dl.opensubtitles.org/sub/44.gz',
          flagUrl: '',
          format: 'srt',
          encoding: 'gzip/auto',
          display: 'English',
          language: 'en',
          media: 'movie',
          isHearingImpaired: false,
          release: 'Example.Release',
          source: 'OpenSubtitles',
        ),
      );

      expect(source.content, contains('WEBVTT'));
      expect(source.content, contains('OpenSubtitles cue'));
      expect(requests.single.headers['user-agent'], 'TemporaryUserAgent');
      expect(requests.single.headers['x-user-agent'], 'TemporaryUserAgent');
    });

    test('keeps different releases while deduplicating repeated release records', () {
      ExternalSubtitle make(String id, String url, String release, String source) =>
          ExternalSubtitle(
            id: id,
            url: url,
            flagUrl: '',
            format: 'srt',
            encoding: 'UTF-8',
            display: 'English',
            language: 'en',
            media: 'movie',
            isHearingImpaired: false,
            release: release,
            source: source,
          );
      final merged = ExternalSubtitleService.mergeSearchResultsForTesting(
        <ExternalSubtitle>[
          make('1', 'https://one.test/1', 'Movie.Release.A', 'OpenSubtitles'),
          make('2', 'https://two.test/2', 'Movie.Release.A', 'SubSource'),
          make('3', 'https://three.test/3', 'Movie.Release.B', 'SubSource'),
        ],
        'en',
      );
      expect(merged, hasLength(2));
      expect(merged.map((item) => item.release), containsAll(<String>[
        'Movie.Release.A',
        'Movie.Release.B',
      ]));
    });

    test('puts Arabic before English when Arabic is the preferred subtitle language', () {
      ExternalSubtitle make({required String id, required String language}) =>
          ExternalSubtitle(
            id: id,
            url: 'https://subtitle.test/$id.srt',
            flagUrl: '',
            format: 'srt',
            encoding: 'UTF-8',
            display: language == 'ar' ? 'Arabic' : 'English',
            language: language,
            media: 'movie',
            isHearingImpaired: false,
            release: 'Release.$id',
            source: 'OpenSubtitles',
          );
      final results = ExternalSubtitleService.mergeSearchResultsForTesting(
        <ExternalSubtitle>[
          make(id: 'en', language: 'en'),
          make(id: 'ar', language: 'ar'),
        ],
        'ar',
      );
      expect(results.first.language, 'ar');
      expect(results.last.language, 'en');
    });

    test('prefers SubSource for Arabic before duplicate-release removal', () {
      ExternalSubtitle make({
        required String id,
        required String source,
        required String url,
      }) => ExternalSubtitle(
            id: id,
            url: url,
            flagUrl: '',
            format: 'srt',
            encoding: 'UTF-8',
            display: 'Arabic',
            language: 'ar',
            media: 'movie',
            isHearingImpaired: false,
            release: 'Resident.Evil.2026.WEB',
            source: source,
          );

      final results = ExternalSubtitleService.mergeSearchResultsForTesting(
        <ExternalSubtitle>[
          make(id: 'opensubs', source: 'OpenSubtitles',
              url: 'https://opensubs.test/ar.srt'),
          make(id: 'scraper', source: 'Scraper API',
              url: 'https://scraper.test/ar.srt'),
          make(id: 'subsource', source: 'SubSource',
              url: 'https://subsource.test/ar.zip'),
        ],
        'ar',
      );

      expect(results, hasLength(1));
      expect(results.single.source, 'SubSource');
    });

    test('episode matching does not confuse E02 with E020', () {
      final matcher = ExternalSubtitleService.episodePatternForTesting(1, 2);
      expect(matcher.hasMatch('Example.S01E02.1080p'), isTrue);
      expect(matcher.hasMatch('Example.1x02.1080p'), isTrue);
      expect(matcher.hasMatch('Example.S01E020.1080p'), isFalse);
    });

    test('keeps SubSource when Arabic providers return the same URL', () {
      ExternalSubtitle make(String source) => ExternalSubtitle(
            id: source,
            url: 'https://subtitles.test/resident-evil-ar.zip',
            flagUrl: '',
            format: 'zip',
            encoding: 'zip/auto',
            display: 'Arabic',
            language: 'ar',
            media: 'movie',
            isHearingImpaired: false,
            release: 'Resident.Evil.2026.WEB',
            source: source,
          );

      final results = ExternalSubtitleService.mergeSearchResultsForTesting(
        <ExternalSubtitle>[
          make('OpenSubtitles'),
          make('SubSource'),
        ],
        'ar',
      );

      expect(results, hasLength(1));
      expect(results.single.source, 'SubSource');
    });

  });
}
