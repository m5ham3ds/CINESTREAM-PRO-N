import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:dio/dio.dart';

import 'media_identity.dart';
import 'source_engine.dart';
import 'source_manifest.dart';
import 'stream_option.dart';
import 'quickjs/quickjs_provider_runtime.dart';
import 'quickjs/quickjs_stream_mapper.dart';

/// Android off-screen WebView resolver matching OpenStream's web-embed and
/// vidking-webview engine contracts. Only captured media URLs are returned to
/// Flutter; the embed page is never treated as a playable stream itself.
class OpenStreamWebEmbedSourceEngine extends SourceEngine {
  OpenStreamWebEmbedSourceEngine({
    required this.engineKind,
    required QuickJsProviderRuntime quickJsRuntime,
    Dio? dio,
  })  : _quickJsRuntime = quickJsRuntime,
        _dio = dio ?? Dio();

  static const MethodChannel _channel =
      MethodChannel('flixquest/openstream_web_embed');

  final SourceEngineKind engineKind;
  final QuickJsProviderRuntime _quickJsRuntime;
  final Dio _dio;

  static const Set<String> _hosterDomains = <String>{
    'filemoon', 'moonplayer', 'kerapoxy', 'fmoonembed', 'cinegrab',
    'streamwish', 'wishembed', 'wishfast', 'sfastwish', 'strwish', 'playerwish',
    'hlswish', 'awish', 'dwish', 'embedwish', 'mwish', 'flaswish', 'obeywish',
    'cdnwish', 'asnwish', 'jodwish', 'streamhg', 'dhcplay', 'hglink',
    'vidhide', 'filelions', 'alions', 'dlions', 'mlions', 'ryderjet', 'smoothpre',
    'movearnpre', 'dinisglows', 'mivalyo', 'dintezuvio', 'voe', 'voe-unblock',
    'voeunblock', 'tubelessceliolymph', 'maxfinishseveral', 'crystaltreatmenteast',
    'graceaddresscommunity', 'christopheruntilpoint', 'launchreliantcleaverriver',
    'jennifercertaindevelopment',
    'mp4upload', 'vidmoly', 'ok.ru', 'odnoklassniki', 'dood', 'streamlare', 'slwatch',
  };

  @override
  SourceEngineKind get kind => engineKind;

  @override
  bool supports(SourceManifest source) => Platform.isAndroid && source.engine.kind == kind;

  @override
  Future<UnifiedSourceResult> resolve({
    required SourceManifest source,
    required MediaIdentity media,
    CancelToken? cancelToken,
  }) async {
    if (!Platform.isAndroid) {
      return const UnifiedSourceResult(
        errorMessage: 'OpenStream Web Embed currently requires the Android WebView bridge.',
      );
    }
    final embedUrl = _embedUrl(source, media);
    if (embedUrl == null) {
      return const UnifiedSourceResult(
        errorMessage: 'This embed template requires an identifier or episode number that is unavailable.',
      );
    }
    final stopwatch = Stopwatch()..start();
    try {
      // OpenStream first attempts direct hoster extraction (Filemoon,
      // StreamWish/VidHide, Voe, Mp4Upload, Vidmoly and OK.ru). This is faster
      // and more reliable than loading the full embed whenever the page
      // exposes its hoster iframe in HTML.
      final nativeStreams = await _resolveNativeHosters(source, embedUrl, cancelToken);
      if (nativeStreams.isNotEmpty) {
        stopwatch.stop();
        return UnifiedSourceResult(streams: nativeStreams, elapsed: stopwatch.elapsed);
      }
      final embedUri = Uri.parse(embedUrl);
      final defaultReferer = '${embedUri.scheme}://${embedUri.host}/';
      final response = await _channel.invokeMethod<List<dynamic>>(
        'resolveEmbed',
        <String, dynamic>{
          'url': embedUrl,
          'referer': defaultReferer,
          'sourceId': source.id,
          'sourceName': source.name,
          'timeoutMs': 18000,
        },
      );
      final streams = <UnifiedStreamOption>[];
      var index = 0;
      for (final raw in response ?? const <dynamic>[]) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final url = (item['url'] ?? '').toString().trim();
        final uri = Uri.tryParse(url);
        if (uri == null ||
            (uri.scheme != 'https' && uri.scheme != 'http') ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          continue;
        }
        index++;
        final headers = _stringMap(item['headers']);
        final rawSubtitles = item['subtitles'];
        final subtitles = rawSubtitles is List
            ? rawSubtitles
                .whereType<Map>()
                .map((track) => UnifiedSubtitleTrack.fromJson(
                      Map<String, dynamic>.from(track),
                    ))
                .where((track) => track.url.isNotEmpty)
                .toList(growable: false)
            : const <UnifiedSubtitleTrack>[];
        streams.add(UnifiedStreamOption(
          id: '${source.id}-web-$index-${url.hashCode}',
          providerId: source.id,
          providerName: source.name,
          url: url,
          label: item['label']?.toString(),
          quality: item['quality']?.toString(),
          container: _container(url, item['container']?.toString()),
          headers: headers,
          subtitles: subtitles,
          audioKind: _audioKind(item['audioKind']?.toString()),
          audioLanguage: item['audioLanguage']?.toString(),
        ));
      }
      stopwatch.stop();
      if (streams.isEmpty) {
        return UnifiedSourceResult(
          errorMessage: '${source.name} embed completed without exposing a playable media URL. '
              'The page may require an unavailable API response, hoster extraction, or an interactive challenge.',
          elapsed: stopwatch.elapsed,
        );
      }
      return UnifiedSourceResult(streams: streams, elapsed: stopwatch.elapsed);
    } on PlatformException catch (error) {
      stopwatch.stop();
      return UnifiedSourceResult(errorMessage: error.message ?? error.code, elapsed: stopwatch.elapsed);
    } catch (error) {
      stopwatch.stop();
      return UnifiedSourceResult(errorMessage: error.toString(), elapsed: stopwatch.elapsed);
    }
  }

  Future<List<UnifiedStreamOption>> _resolveNativeHosters(
    SourceManifest source,
    String embedUrl,
    CancelToken? cancelToken,
  ) async {
    final candidates = <String>{};
    if (_isSupportedHoster(Uri.tryParse(embedUrl)?.host ?? '')) candidates.add(embedUrl);
    try {
      final response = await _dio.get<String>(
        embedUrl,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 12),
          sendTimeout: const Duration(seconds: 12),
          headers: <String, String>{
            'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/126.0 Mobile Safari/537.36',
            'Referer': '${Uri.parse(embedUrl).origin}/',
          },
          validateStatus: (status) => status != null && status >= 200 && status < 400,
        ),
      );
      final html = response.data ?? '';
      // OpenStream scans quoted absolute URLs because hoster links may live in
      // inline JavaScript/JSON instead of src/href attributes.
      final linkPattern = RegExp(
        r"""["'](https?://[^"'\s<>]+)["']""",
        caseSensitive: false,
      );
      for (final match in linkPattern.allMatches(html)) {
        final raw = match.group(1)?.trim() ?? '';
        if (raw.isEmpty) continue;
        final absolute = Uri.tryParse(raw);
        if (absolute == null ||
            (absolute.scheme != 'https' && absolute.scheme != 'http') ||
            absolute.host.isEmpty ||
            absolute.userInfo.isNotEmpty) {
          continue;
        }
        if (_isSupportedHoster(absolute.host)) candidates.add(absolute.toString());
        if (candidates.length >= 10) break;
      }
    } catch (_) {
      // Some embeds deliberately reject a plain HTTP client; the WebView
      // fallback below remains the authoritative dynamic-page path.
    }
    if (candidates.isEmpty) return const <UnifiedStreamOption>[];

    final results = <UnifiedStreamOption>[];
    for (final candidate in candidates.take(10)) {
      try {
        final raw = await _quickJsRuntime.extractVideo(
          candidate,
          options: <String, dynamic>{
            'headers': <String, String>{
              'Referer': embedUrl,
              'Origin': Uri.parse(embedUrl).origin,
              'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/126.0 Mobile Safari/537.36',
            },
          },
          timeout: const Duration(seconds: 18),
          cancelToken: cancelToken,
        );
        results.addAll(mapQuickJsVideoSources(source, raw, idPrefix: 'openstream-hoster'));
      } catch (_) {
        // Unsupported or changed hosters fall back to the WebView sniffer.
      }
    }
    final seen = <String>{};
    return results.where((stream) => seen.add('${stream.url}|${stream.headers}')).toList(growable: false);
  }

  bool _isSupportedHoster(String host) {
    final normalized = host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    return _hosterDomains.any((domain) =>
        normalized == domain || normalized.endsWith('.$domain'));
  }

  String? _embedUrl(SourceManifest source, MediaIdentity media) {
    String? template;
    if (source.engine.kind == SourceEngineKind.vidkingWebView) {
      template = media.type == UnifiedMediaType.movie
          ? 'https://www.vidking.net/embed/movie/{tmdbId}?autoPlay=true'
          : 'https://www.vidking.net/embed/tv/{tmdbId}/{season}/{episode}?autoPlay=true';
    } else {
      template = media.type == UnifiedMediaType.movie
          ? source.engine.movieUrl
          : source.engine.tvUrl;
    }
    if (template == null || !template.startsWith('https://')) return null;
    if (template.contains('{tmdbId}') && media.tmdbId == null) return null;
    if (template.contains('{imdbId}') && media.imdbId == null) return null;
    if (media.type != UnifiedMediaType.movie && !media.isEpisode) return null;
    final value = template
        .replaceAll('{tmdbId}', media.tmdbId?.toString() ?? '')
        .replaceAll('{imdbId}', media.imdbId ?? '')
        .replaceAll('{season}', media.seasonNumber?.toString() ?? '')
        .replaceAll('{episode}', media.episodeNumber?.toString() ?? '');
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return null;
    }
    return value;
  }

  Map<String, String> _stringMap(dynamic value) {
    if (value is! Map) return const <String, String>{};
    return <String, String>{
      for (final entry in value.entries)
        if (entry.value != null) entry.key.toString(): entry.value.toString(),
    };
  }

  StreamContainer _container(String url, String? value) {
    final text = '${value ?? ''} $url'.toLowerCase();
    if (text.contains('.m3u8') || text.contains('hls')) return StreamContainer.hls;
    if (text.contains('.mpd') || text.contains('dash')) return StreamContainer.dash;
    if (text.contains('.mp4')) return StreamContainer.mp4;
    if (text.contains('.webm')) return StreamContainer.webm;
    return StreamContainer.unknown;
  }

  StreamAudioKind _audioKind(String? value) {
    switch (value?.toLowerCase()) {
      case 'sub':
      case 'subbed':
        return StreamAudioKind.sub;
      case 'dub':
      case 'dubbed':
        return StreamAudioKind.dub;
      case 'raw':
        return StreamAudioKind.raw;
      default:
        return StreamAudioKind.unknown;
    }
  }
}
