import 'dart:io';

import 'package:flixquest/video_providers/unified/source_manifest.dart';
import 'package:flixquest/video_providers/unified/source_repository_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parser = SourceRepositoryParser();

  group('SourceRepositoryParser', () {
    test('parses OpenStream-style extension entries and keeps engine metadata',
        () async {
      // A representative OpenStream-style descriptor fixture.
      const json = '''
      {
        "manifestVersion": 1,
        "name": "Example Repo",
        "extensions": [
          {
            "id": "addon-one",
            "name": "Addon One",
            "version": "1.2.0",
            "versionCode": 2,
            "language": "Multi",
            "tags": ["movies", "series"],
            "engine": {
              "type": "stremio",
              "endpoint": "https://addon.example",
              "priority": 7
            }
          }
        ]
      }
      ''';
      final repository = parser.parseRepository(
        json,
        sourceUrl: 'https://repo.example/index.json',
      );

      expect(repository.name, 'Example Repo');
      expect(repository.extensions, hasLength(1));
      expect(repository.extensions.single.engine.kind, SourceEngineKind.stremio);
      expect(repository.extensions.single.installedByDefault, isFalse);
      expect(repository.extensions.single.engine.priority, 7);
      expect(repository.extensions.single.repositoryUrl,
          'https://repo.example/index.json');
    });

    test('parses a Stremio manifest URL as a source entry', () {
      const json = '''
      {
        "id": "org.example.addon",
        "version": "1.0.0",
        "name": "Example Stremio Addon",
        "description": "Test addon",
        "resources": ["catalog", "stream"],
        "types": ["movie", "series"],
        "idPrefixes": ["tt"]
      }
      ''';
      final repository = parser.parseRepository(
        json,
        sourceUrl: 'https://addon.example/config/manifest.json',
      );

      expect(repository.isStremioAddon, isTrue);
      expect(repository.extensions.single.engine.kind, SourceEngineKind.stremio);
      expect(repository.extensions.single.installedByDefault, isTrue);
      expect(repository.extensions.single.engine.endpoint,
          'https://addon.example/config');
      expect(repository.extensions.single.engine.config['types'],
          containsAll(<String>['movie', 'series']));
    });

    test('reads Stremio stream resource types and idPrefixes', () {
      const json = '''
      {
        "id": "org.example.resource-prefixes",
        "name": "Resource Prefix Addon",
        "resources": [
          {"name": "catalog", "types": ["movie"]},
          {"name": "stream", "types": ["series"], "idPrefixes": ["kitsu:", "anilist:"]}
        ]
      }
      ''';
      final repository = parser.parseRepository(
        json,
        sourceUrl: 'https://addon.example/manifest.json',
      );
      final source = repository.extensions.single;

      expect(source.engine.kind, SourceEngineKind.stremio);
      expect(source.engine.config['types'], contains('series'));
      expect(source.engine.config['types'], isNot(contains('movie')));
      expect(source.engine.config['idPrefixes'], containsAll(['kitsu:', 'anilist:']));
    });

    test('leaves omitted Stremio idPrefixes unspecified for IMDb default handling', () {
      const json = '''
      {
        "id": "org.example.no-prefix",
        "name": "No Prefix Addon",
        "resources": ["stream"],
        "types": ["movie"]
      }
      ''';
      final repository = parser.parseRepository(
        json,
        sourceUrl: 'https://addon.example/manifest.json',
      );

      expect(repository.extensions.single.engine.config.containsKey('idPrefixes'),
          isFalse);
    });

    test('does not mark a Stremio entry runnable without a valid endpoint', () {
      const json = '''
      {
        "name": "Repo",
        "extensions": [
          {"id":"broken-addon","name":"Broken Addon","engine":{"type":"stremio"}}
        ]
      }
      ''';
      final repository = parser.parseRepository(
        json,
        sourceUrl: 'https://repo.example/index.json',
      );

      expect(repository.extensions.single.engine.kind,
          SourceEngineKind.unsupported);
      expect(repository.extensions.single.isRunnable, isFalse);
    });

    test('recognizes OpenStream Vidking entries as runnable engine manifests',
        () {
      const json = '''
      {
        "name": "OpenStream Official",
        "extensions": [
          {
            "id": "yoru",
            "name": "Yoru",
            "installedByDefault": true,
            "status": 1,
            "engine": {
              "type": "vidking-direct",
              "endpoint": "cdn/sources-with-title",
              "priority": 0
            }
          }
        ]
      }
      ''';
      final repository = parser.parseRepository(
        json,
        sourceUrl: 'https://repo.example/index.json',
      );
      final source = repository.extensions.single;

      expect(source.id, 'yoru');
      expect(source.installedByDefault, isTrue);
      expect(source.engine.rawType, 'vidking-direct');
      expect(source.engine.kind, SourceEngineKind.vidkingDirect);
      expect(source.isRunnable, isTrue);
    });

    test('parses all engine families in the OpenStream official repository fixture', () async {
      final raw = await File('test/fixtures/openstream_official_repo.json').readAsString();
      final repository = parser.parseRepository(
        raw,
        sourceUrl: 'https://raw.githubusercontent.com/Ivorisnoob/OpenStream/main/extensions/index.json',
      );

      expect(repository.extensions, hasLength(30));
      final byType = <String, List<SourceManifest>>{};
      for (final source in repository.extensions) {
        byType.putIfAbsent(source.engine.rawType, () => <SourceManifest>[]).add(source);
      }
      expect(byType['vidking-direct'], hasLength(9));
      expect(byType['stremio'], hasLength(5));
      expect(byType['web-embed'], hasLength(10));
      expect(byType['vidking-webview'], hasLength(1));
      expect(byType['anikoto'], hasLength(1));
      expect(byType['reanime'], hasLength(1));
      expect(byType['animepahe'], hasLength(1));
      expect(byType['fouranimo'], hasLength(1));
      expect(byType['animegg'], hasLength(1));

      expect(byType['vidking-direct']!.every((source) => source.engine.kind == SourceEngineKind.vidkingDirect), isTrue);
      expect(byType['stremio']!.every((source) => source.engine.kind == SourceEngineKind.stremio), isTrue);
      expect(byType['web-embed']!.every((source) => source.engine.kind == SourceEngineKind.webEmbed), isTrue);
      // OpenStream Web Embed providers support movies as well as series.
      // Jett is the reference movie route used by the working OpenStream app.
      final jett = byType['web-embed']!.singleWhere(
        (source) => source.id == 'jett',
      );
      expect(jett.engine.movieUrl, 'https://vidlink.pro/movie/{tmdbId}');
      expect(
        jett.engine.tvUrl,
        'https://vidlink.pro/tv/{tmdbId}/{season}/{episode}',
      );
      expect(jett.tags, containsAll(<String>['movies', 'series']));
      expect(jett.isFallback, isTrue);
      expect(jett.status, 3); // Beta is playable; only status 0 means down.
      expect(byType['vidking-webview']!.single.engine.kind, SourceEngineKind.vidkingWebView);
      expect(
        byType['vidking-direct']!.every((source) => !source.isFallback),
        isTrue,
      );
      expect(
        byType['web-embed']!.every((source) => source.isFallback),
        isTrue,
      );
      expect(byType['vidking-webview']!.single.isFallback, isTrue);
      for (final type in ['anikoto', 'reanime', 'animepahe', 'fouranimo', 'animegg']) {
        expect(byType[type]!.single.engine.kind, SourceEngineKind.animeSite);
        expect(byType[type]!.single.isRunnable, isTrue);
      }
      expect(repository.extensions.where((source) => source.isRunnable), hasLength(30));
    });

    test('parses Zangetsu JavaScript source repositories without running them', () {
      const json = '''
      {
        "name": "Zangetsu Sources",
        "description": "Example JS provider repository",
        "sources": [
          {
            "id": "allanime",
            "name": "AllAnime",
            "version": "1.0.0",
            "type": "anime",
            "lang": "en",
            "file": "providers/allanime.js",
            "logo": "icons/allanime.png",
            "nsfw": false
          }
        ]
      }
      ''';
      final repository = parser.parseRepository(
        json,
        sourceUrl: 'https://repo.example/zangetsu/index.json',
      );
      final source = repository.extensions.single;

      expect(source.name, 'AllAnime');
      expect(source.engine.rawType, 'javascript');
      expect(source.engine.kind, SourceEngineKind.javascript);
      expect(source.engine.endpoint,
          'https://repo.example/zangetsu/providers/allanime.js');
      expect(source.iconUrl,
          'https://repo.example/zangetsu/icons/allanime.png');
      expect(source.engine.config['providerType'], 'anime');
      expect(source.installedByDefault, isFalse);
    });


    test('classifies only explicitly anime-exclusive sources as anime-only', () {
      const json = '''
      {
        "name": "Capability fixtures",
        "extensions": [
          {
            "id": "anime-site",
            "name": "Anime Site",
            "tags": ["anime", "sub", "dub"],
            "engine": {"type": "anikoto", "endpoint": "https://anime.example/api"}
          },
          {
            "id": "multi-vidking",
            "name": "Multi Vidking",
            "tags": ["anime", "movies", "series"],
            "engine": {"type": "vidking-direct", "endpoint": "cdn/sources-with-title"}
          },
          {
            "id": "multi-embed",
            "name": "Multi Embed",
            "tags": ["movies", "series", "anime", "fallback"],
            "engine": {
              "type": "web-embed",
              "movieUrl": "https://embed.example/movie/{tmdbId}",
              "tvUrl": "https://embed.example/tv/{tmdbId}/{season}/{episode}"
            }
          }
        ]
      }
      ''';
      final parsed = parser.parseRepository(
        json,
        sourceUrl: 'https://repo.example/capabilities.json',
      ).extensions;
      final byId = {for (final source in parsed) source.id: source};

      expect(byId['anime-site']!.isAnimeOnly, isTrue);
      expect(byId['multi-vidking']!.isAnimeOnly, isFalse);
      expect(byId['multi-embed']!.isAnimeOnly, isFalse);
    });

    test('Zangetsu sources without a declared content type default to all', () {
      const json = '''
      {
        "name": "Generic JavaScript sources",
        "sources": [
          {"id": "generic", "name": "Generic", "file": "providers/generic.js"},
          {"id": "anime", "name": "Anime", "type": "anime", "file": "providers/anime.js"}
        ]
      }
      ''';
      final parsed = parser.parseRepository(
        json,
        sourceUrl: 'https://repo.example/zangetsu/index.json',
      ).extensions;
      final byId = {for (final source in parsed) source.id: source};

      expect(byId['generic']!.engine.config['providerType'], 'all');
      expect(byId['generic']!.isAnimeOnly, isFalse);
      expect(byId['anime']!.engine.config['providerType'], 'anime');
      expect(byId['anime']!.isAnimeOnly, isTrue);
    });

    test('keeps unknown engine entries visible but marks them unsupported', () {
      const json = '''
      {
        "name": "Repo",
        "extensions": [
          {"id":"future","name":"Future","engine":{"type":"new-engine"}}
        ]
      }
      ''';
      final repository = parser.parseRepository(
        json,
        sourceUrl: 'https://repo.example/index.json',
      );
      expect(repository.extensions.single.engine.kind,
          SourceEngineKind.unsupported);
      expect(repository.extensions.single.isRunnable, isFalse);
    });
  });
}
