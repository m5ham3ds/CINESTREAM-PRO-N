import 'dart:convert';

import 'package:http/http.dart' as http;

import 'common.dart';

/// Reads variant heights from an adaptive HLS or DASH manifest without
/// starting playback. The request uses the same headers as the stream link.
class AdaptiveQualityScanner {
  AdaptiveQualityScanner({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 10);
  static const int _maxManifestBytes = 2 * 1024 * 1024;

  Future<List<int>> scan(RegularVideoLinks link) async {
    final rawUrl = link.url?.trim() ?? '';
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return _normalized(link.availableHeights);
    }

    final path = uri.path.toLowerCase();
    final declaredDash = link.isDash == true || path.endsWith('.mpd');
    final declaredHls = link.isM3U8 == true || path.endsWith('.m3u8');
    final declaredAdaptive = link.isAdaptive ||
        link.availableHeights.isNotEmpty ||
        _isAutoQuality(link.quality);
    if (!declaredAdaptive && !declaredDash && !declaredHls) {
      return _normalized(link.availableHeights);
    }

    try {
      final response = await _getManifest(uri, link.headers);
      if (response == null) return _normalized(link.availableHeights);

      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      final contentType =
          response.headers['content-type']?.toLowerCase() ?? '';
      final finalBody = body.replaceFirst('\uFEFF', '').trimLeft();
      final lowerBody = finalBody.toLowerCase();
      final isDash = declaredDash ||
          contentType.contains('dash+xml') ||
          lowerBody.startsWith('<?xml') && lowerBody.contains('<mpd') ||
          lowerBody.startsWith('<mpd');
      final isHls = declaredHls ||
          contentType.contains('mpegurl') ||
          finalBody.startsWith('#EXTM3U');

      if (isDash) {
        return _normalized(<int>[
          ...link.availableHeights,
          ...parseDashHeights(body),
        ]);
      }
      if (!isHls) return _normalized(link.availableHeights);

      final manifestHeights = parseHlsHeights(body);
      final baseUri = response.request?.url ?? uri;
      final heights = <int>[
        ...link.availableHeights,
        ...manifestHeights,
        ..._hlsVariantUriHeights(body, baseUri),
      ];

      // Some providers return a wrapper/master playlist without rendition
      // heights. Only in that case follow a bounded number of child playlists.
      // Never forward provider authorization/cookie headers across hosts.
      final nestedUris = manifestHeights.isEmpty
          ? _hlsVariantUris(body, response.request?.url ?? uri)
              .take(_maxNestedHlsPlaylists)
              .toList(growable: false)
          : const <Uri>[];
      if (nestedUris.isNotEmpty) {
        final nestedResults = await Future.wait(
          nestedUris.map((nestedUri) async {
            // Relative URLs resolve against the final manifest URL, but
            // sensitive headers remain scoped to the original source host.
            final nestedHeaders = _headersForNestedUri(
              uri,
              nestedUri,
              link.headers,
            );
            final nested = await _getManifest(nestedUri, nestedHeaders);
            if (nested == null) return const <int>[];
            final nestedBody =
                utf8.decode(nested.bodyBytes, allowMalformed: true);
            return parseHlsHeights(nestedBody);
          }),
        );
        for (final nested in nestedResults) {
          heights.addAll(nested);
        }
      }
      return _normalized(heights);
    } catch (_) {
      // Manifest discovery is opportunistic and must never block playback.
      return _normalized(link.availableHeights);
    }
  }

  static const int _maxNestedHlsPlaylists = 8;

  static bool _isAutoQuality(String? quality) {
    final value = quality?.trim().toLowerCase() ?? '';
    return value.startsWith('auto') ||
        value.startsWith('adaptive') ||
        value.startsWith('master');
  }

  Future<http.Response?> _getManifest(
    Uri uri,
    Map<String, String>? headers,
  ) async {
    try {
      final response = await _client
          .get(uri, headers: headers ?? const <String, String>{})
          .timeout(_timeout);
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.bodyBytes.isEmpty ||
          response.bodyBytes.length > _maxManifestBytes) {
        return null;
      }
      return response;
    } catch (_) {
      return null;
    }
  }

  static Iterable<Uri> _hlsVariantUris(String manifest, Uri baseUri) sync* {
    // RFC 8216 normally puts the variant URI on the next line. Some providers
    // insert blank lines or comments between the tag and URI, so parse the
    // line sequence instead of assuming a fixed one-line regex match.
    final lines = manifest.split(RegExp(r'\r?\n'));
    final seen = <String>{};
    for (var index = 0; index < lines.length; index++) {
      if (!lines[index].trimLeft().toUpperCase().startsWith(
            '#EXT-X-STREAM-INF:',
          )) {
        continue;
      }
      var uriLine = index + 1;
      while (uriLine < lines.length) {
        final candidate = lines[uriLine].trim();
        if (candidate.isNotEmpty && !candidate.startsWith('#')) break;
        uriLine++;
      }
      if (uriLine >= lines.length) continue;
      final value = lines[uriLine].trim();
      final uri = Uri.tryParse(value);
      if (uri == null) continue;
      final resolved = uri.hasScheme ? uri : baseUri.resolveUri(uri);
      if ((resolved.scheme == 'http' || resolved.scheme == 'https') &&
          seen.add(resolved.toString())) {
        yield resolved;
      }
      index = uriLine;
    }
  }

  static List<int> _hlsVariantUriHeights(String manifest, Uri baseUri) {
    final heights = <int>[];
    for (final uri in _hlsVariantUris(manifest, baseUri)) {
      // Some providers omit RESOLUTION and NAME, but expose variants as
      // /1080p/index.m3u8 or /720/stream.m3u8. Only accept explicit path
      // segments to avoid treating arbitrary numeric IDs as video heights.
      for (final segment in uri.pathSegments.reversed) {
        var candidate = segment.trim().toLowerCase();
        candidate = candidate.replaceFirst(
          RegExp(r'\.(?:m3u8|mp4|mpd|webm)$'),
          '',
        );
        final match = RegExp(r'^(\d{2,5})p?$').firstMatch(candidate);
        if (match == null) continue;
        final height = int.tryParse(match.group(1) ?? '');
        if (height != null && height > 0 && height <= 16384) {
          heights.add(height);
          break;
        }
      }
      for (final key in const <String>['height', 'quality', 'resolution']) {
        final value = uri.queryParameters[key];
        if (value == null) continue;
        final match = RegExp(r'(?<!\d)(\d{2,5})\s*p?\b',
                caseSensitive: false)
            .firstMatch(value);
        final height = int.tryParse(match?.group(1) ?? '');
        if (height != null && height > 0 && height <= 16384) {
          heights.add(height);
        }
      }
    }
    return _normalized(heights);
  }

  static Map<String, String> _headersForNestedUri(
    Uri origin,
    Uri target,
    Map<String, String>? sourceHeaders,
  ) {
    final headers = sourceHeaders ?? const <String, String>{};
    if (origin.host.toLowerCase() == target.host.toLowerCase()) {
      return Map<String, String>.of(headers);
    }
    // Do not forward provider credentials to a different CDN host.
    return <String, String>{
      for (final entry in headers.entries)
        if (entry.key.toLowerCase() == 'user-agent' ||
            entry.key.toLowerCase() == 'accept')
          entry.key: entry.value,
    };
  }

  static List<int> parseHlsHeights(String manifest) {
    final values = <int>[];
    final pattern = RegExp(
      r'#EXT-X-STREAM-INF:([^\r\n]*)',
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(manifest)) {
      final attributes = match.group(1) ?? '';
      final resolution = RegExp(
        r'RESOLUTION\s*=\s*\d+\s*[xX]\s*(\d+)',
        caseSensitive: false,
      ).firstMatch(attributes);
      final namedQuality = RegExp(
        r'''NAME\s*=\s*["']([^"']+)''',
        caseSensitive: false,
      ).firstMatch(attributes);
      final namedHeight = RegExp(
        r'(?<!\d)(\d{3,4})\s*p?\b',
        caseSensitive: false,
      ).firstMatch(namedQuality?.group(1) ?? '');
      final height = int.tryParse(
        resolution?.group(1) ?? namedHeight?.group(1) ?? '',
      );
      if (height != null && height > 0) values.add(height);
    }
    return _normalized(values);
  }

  static List<int> parseDashHeights(String manifest) {
    final values = <int>[];
    final representation = RegExp(
      r'''<Representation\b[^>]*\bheight\s*=\s*["'](\d+)["'][^>]*>''',
      caseSensitive: false,
    );
    for (final match in representation.allMatches(manifest)) {
      final height = int.tryParse(match.group(1) ?? '');
      if (height != null && height > 0) values.add(height);
    }
    return _normalized(values);
  }

  static List<int> _normalized(Iterable<int> heights) {
    final result = heights
        .where((height) => height > 0 && height <= 16384)
        .toSet()
        .toList(growable: false);
    result.sort((a, b) => b.compareTo(a));
    return result;
  }

  void dispose() => _client.close();
}
