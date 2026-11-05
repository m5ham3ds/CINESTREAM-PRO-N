import '../common.dart';
import 'source_engine.dart';
import 'stream_option.dart';
import 'unified_source_service.dart';

/// Transitional adapter for FlixQuest's existing direct and scraper providers.
/// It lets the new source pipeline consume the old result without changing the
/// player screen in the same commit.
extension LegacyProviderResultAdapter on ProviderLoadResult {
  UnifiedSourceResult toUnifiedSourceResult({
    required String providerId,
    required String providerName,
  }) {
    final globalSubtitles = <UnifiedSubtitleTrack>[
      for (final subtitle in subtitleLinks ?? const <RegularSubtitleLinks>[])
        if (subtitle.url?.trim().isNotEmpty == true)
          UnifiedSubtitleTrack(
            url: subtitle.url!.trim(),
            language: subtitle.language ?? 'und',
            headers: subtitle.headers ?? const <String, String>{},
          ),
    ];

    final streams = <UnifiedStreamOption>[];
    for (var index = 0; index < (videoLinks?.length ?? 0); index++) {
      final link = videoLinks![index];
      final url = link.url?.trim();
      if (url == null || url.isEmpty) continue;
      final container = link.isM3U8 == true
          ? StreamContainer.hls
          : link.isDash == true
              ? StreamContainer.dash
              : _containerFromUrl(url);
      streams.add(
        UnifiedStreamOption(
          id: '$providerId::$index',
          providerId: providerId,
          providerName: providerName,
          url: url,
          label: link.server,
          quality: link.quality,
          container: container,
          headers: link.headers ?? const <String, String>{},
          subtitles: globalSubtitles,
          metadata: <String, dynamic>{
            if (link.sizeToken != null) 'sizeToken': link.sizeToken,
            if (link.server != null) 'server': link.server,
            if (link.isAdaptive) 'adaptiveMaster': true,
            if (link.availableHeights.isNotEmpty)
              'availableHeights': List<int>.of(link.availableHeights),
          },
        ),
      );
    }

    return UnifiedSourceResult(
      streams: streams,
      errorMessage: errorMessage,
    );
  }
}

/// Converts one engine attempt into the legacy provider result consumed by
/// the existing BetterPlayer picker. Keeping this adapter at attempt level
/// lets sources resolve concurrently without losing provider attribution.
extension UnifiedAttemptLegacyAdapter on UnifiedSourceAttempt {
  ProviderLoadResult toProviderLoadResult() => _providerLoadResult(
        result.streams,
        errorMessage: result.errorMessage,
        fallbackMessage:
            'No playable stream was returned by ${source.name}.',
      );
}

/// Bridges a completed repository search into the legacy player result.
extension UnifiedSearchResultLegacyAdapter on UnifiedSourceSearchResult {
  ProviderLoadResult toProviderLoadResult() => _providerLoadResult(
        streams,
        errorMessage: attempts
            .map((attempt) => attempt.result.errorMessage)
            .whereType<String>()
            .firstWhere((message) => message.isNotEmpty, orElse: () => ''),
        fallbackMessage: 'No playable streams were returned by installed sources.',
      );
}

ProviderLoadResult _providerLoadResult(
  Iterable<UnifiedStreamOption> sourceStreams, {
  required String? errorMessage,
  required String fallbackMessage,
}) {
  final links = <RegularVideoLinks>[];
  final subtitlesByKey = <String, RegularSubtitleLinks>{};

  for (final stream in sourceStreams) {
    if (!stream.isPlayable || stream.isExpired || !_isHttpStreamUrl(stream.url)) continue;
    final declaredQuality = stream.quality?.trim();
    final baseQuality = declaredQuality?.isNotEmpty == true &&
            declaredQuality!.toLowerCase() != 'unknown quality' &&
            declaredQuality.toLowerCase() != 'unknown'
        ? declaredQuality
        : (stream.height != null && stream.height! > 0)
            ? '${stream.height}p'
            : stream.label?.trim().isNotEmpty == true
                ? stream.label!.trim()
                : 'Auto';
    final audioLabel = stream.audioLanguage?.trim().isNotEmpty == true
        ? stream.audioLanguage!.trim()
        : stream.audioKind == StreamAudioKind.dub
            ? 'Dub'
            : stream.audioKind == StreamAudioKind.sub
                ? 'Sub'
                : '';
    final qualityLabel = <String>[
      baseQuality,
      stream.providerName,
      if (audioLabel.isNotEmpty) audioLabel,
    ].join(' · ');
    links.add(
      RegularVideoLinks(
        url: stream.url,
        quality: qualityLabel,
        server: stream.providerName,
        isM3U8: stream.container == StreamContainer.hls,
        isDash: stream.container == StreamContainer.dash,
        headers: stream.headers.isEmpty
            ? null
            : Map<String, String>.of(stream.headers),
        expiresAt: stream.expiresAt,
        isAdaptive: stream.metadata['adaptiveMaster'] == true,
        availableHeights: stream.metadata['availableHeights'] is List
            ? (stream.metadata['availableHeights'] as List)
                .map((value) => int.tryParse(value.toString()))
                .whereType<int>()
                .where((height) => height > 0)
                .toSet()
                .toList(growable: false)
            : const <int>[],
      ),
    );
    for (final subtitle in stream.subtitles) {
      final key = '${subtitle.url}::${subtitle.language}::${subtitle.headers}';
      subtitlesByKey.putIfAbsent(
        key,
        () => RegularSubtitleLinks(
          url: subtitle.url,
          language: subtitle.label ?? subtitle.language,
          headers: subtitle.headers.isEmpty
              ? null
              : Map<String, String>.of(subtitle.headers),
        ),
      );
    }
  }

  final resolvedError = errorMessage?.trim();
  return ProviderLoadResult(
    videoLinks: links,
    subtitleLinks: subtitlesByKey.values.toList(growable: false),
    success: links.isNotEmpty,
    errorMessage: links.isNotEmpty
        ? null
        : (resolvedError == null || resolvedError.isEmpty
            ? fallbackMessage
            : resolvedError),
  );
}

StreamContainer _containerFromUrl(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  if (path.endsWith('.m3u8')) return StreamContainer.hls;
  if (path.endsWith('.mpd')) return StreamContainer.dash;
  if (path.endsWith('.mp4') || path.endsWith('.m4v')) return StreamContainer.mp4;
  if (path.endsWith('.webm')) return StreamContainer.webm;
  return StreamContainer.unknown;
}


bool _isHttpStreamUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}
