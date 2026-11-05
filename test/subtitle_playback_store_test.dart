import 'dart:io';

import 'package:flixquest/models/external_subtitles.dart';
import 'package:flixquest/services/subtitle_playback_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:better_player_plus/better_player_plus.dart';

void main() {
  late Directory temporaryDirectory;
  late SubtitlePlaybackStore store;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'cinestream-subtitle-store-test-',
    );
    store = SubtitlePlaybackStore(
      supportDirectory: () async => temporaryDirectory,
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('persists Arabic WebVTT bytes and language/provider metadata', () async {
    final subtitle = ExternalSubtitle(
      id: 'opensubtitles_ar_101',
      url: 'https://example.test/arabic.srt',
      flagUrl: '',
      format: 'srt',
      encoding: 'UTF-8',
      display: 'Arabic',
      // OpenSubtitles legacy commonly reports ISO 639-2 `ara`.
      language: 'ara',
      media: 'movie',
      isHearingImpaired: false,
      release: 'Resident.Evil.2026',
      source: 'OpenSubtitles',
    );
    const webVtt = 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nمرحبا بالعالم\n';

    await store.save(
      mediaKey: 'movie_12345',
      subtitle: subtitle,
      webVtt: webVtt,
    );

    final restored = await store.read('movie_12345');
    expect(restored, hasLength(1));
    expect(restored.single.language, 'ar');
    expect(restored.single.display, 'Arabic');
    expect(restored.single.source, 'OpenSubtitles');
    expect(await File(restored.single.filePath).readAsString(), contains('مرحبا بالعالم'));

    final playerSource = restored.single.toPlayerSource(selectedByDefault: true);
    expect(playerSource.type, BetterPlayerSubtitlesSourceType.file);
    expect(playerSource.selectedByDefault, isTrue);
    expect(playerSource.name, contains('Arabic'));
    expect(playerSource.name, contains('OpenSubtitles'));
  });

  test('normalizes readable Arabic and English names to ISO language codes', () async {
    for (final item in <({String id, String language, String display})>[
      (id: 'arabic_alias', language: 'Arabic', display: 'Arabic'),
      (id: 'english_alias', language: 'English', display: 'English'),
    ]) {
      await store.save(
        mediaKey: 'movie_language_aliases',
        subtitle: ExternalSubtitle(
          id: item.id,
          url: 'https://example.test/${item.id}.srt',
          flagUrl: '',
          format: 'srt',
          encoding: 'UTF-8',
          display: item.display,
          language: item.language,
          media: 'movie',
          isHearingImpaired: false,
          release: 'Example.Release',
          source: 'OpenSubtitles',
        ),
        webVtt: 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nSubtitle\n',
      );
    }

    final restored = await store.read('movie_language_aliases');
    expect(
      restored.map((track) => track.language).toSet(),
      containsAll(<String>{'ar', 'en'}),
    );
  });

  test('does not restore missing or invalid subtitle files', () async {
    const invalidVtt = 'this is not a subtitle file';
    final subtitle = ExternalSubtitle(
      id: 'bad_track',
      url: 'https://example.test/bad.srt',
      flagUrl: '',
      format: 'srt',
      encoding: 'UTF-8',
      display: 'Arabic',
      language: 'ar',
      media: 'movie',
      isHearingImpaired: false,
      release: '',
      source: 'OpenSubtitles',
    );
    expect(
      () => store.save(
        mediaKey: 'movie_1',
        subtitle: subtitle,
        webVtt: invalidVtt,
      ),
      throwsFormatException,
    );
    expect(await store.read('movie_1'), isEmpty);
  });
}
