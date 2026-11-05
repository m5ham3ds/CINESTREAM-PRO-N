import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../source_manifest.dart';
import 'crypto_ops.dart';
import 'js_bootstrap.dart';
import 'js_engine.dart';
import 'quickjs_exception.dart';

/// Runs Zangetsu-compatible JavaScript video providers in a single serialized
/// QuickJS runtime. Network access is mediated by Dio; scripts never receive
/// Flutter objects or application credentials.
class QuickJsProviderRuntime {
  QuickJsProviderRuntime({Dio? dio}) : _dio = dio ?? Dio();

  static const Duration _maxCallTime = Duration(seconds: 65);
  static const int _maxScriptBytes = 1536 * 1024;
  static const int _maxResponseBytes = 8 * 1024 * 1024;
  static const Map<String, String> _extractorAssets = <String, String>{
    'doodstream': 'assets/video_providers/extractors/doodstream.js',
    'mp4upload': 'assets/video_providers/extractors/mp4upload.js',
    'okru': 'assets/video_providers/extractors/okru.js',
    'streamlare': 'assets/video_providers/extractors/streamlare.js',
    'filemoon': 'assets/video_providers/extractors/filemoon.js',
    'streamwish': 'assets/video_providers/extractors/streamwish.js',
    'voe': 'assets/video_providers/extractors/voe.js',
    'vidmoly': 'assets/video_providers/extractors/vidmoly.js',
    'example_embed': 'assets/video_providers/extractors/example_embed.js',
  };

  final Dio _dio;
  late final JsEngine _engine = JsEngine(onChannel: _onChannel);
  Future<void> _tail = Future<void>.value();
  final Set<String> _loadedSources = <String>{};
  bool _extractorsLoaded = false;
  bool _disposed = false;
  CancelToken? _activeCancelToken;

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        if (_disposed) throw const JsRuntimeException('JavaScript runtime is closed.');
        completer.complete(await operation());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> ensureProviderLoaded(SourceManifest source, {CancelToken? cancelToken}) async {
    final sourceId = _runtimeSourceId(source);
    if (_loadedSources.contains(sourceId)) return;
    final scriptUrl = source.engine.endpoint.trim();
    _validateHttpUrl(scriptUrl);

    final response = await _dio.get<String>(
      scriptUrl,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 20),
        headers: const <String, String>{'Accept': 'text/javascript, application/javascript, */*'},
        validateStatus: (status) => status != null && status >= 200 && status < 300,
      ),
    );
    // Dio follows redirects by default. Validate the final destination too,
    // so a public repository URL cannot hand the runtime a local/private script
    // after an HTTP redirect.
    _validateHttpUrl(response.realUri.toString());
    final script = response.data ?? '';
    if (script.trim().isEmpty) throw const FormatException('Provider script is empty.');
    if (utf8.encode(script).length > _maxScriptBytes) {
      throw const FormatException('Provider script exceeds the 1.5 MB safety limit.');
    }

    await _serialized(() async {
      if (_loadedSources.contains(sourceId)) return;
      await _engine.ready;
      await _loadBundledExtractors();
      final result = await _engine.eval(wrapProviderSource(sourceId, script));
      if (result.isError) {
        throw JsRuntimeException('Provider ${source.name} failed to load: ${result.value}');
      }
      _loadedSources.add(sourceId);
    });
  }

  Future<void> _loadBundledExtractors() async {
    if (_extractorsLoaded) return;
    for (final entry in _extractorAssets.entries) {
      try {
        final script = await rootBundle.loadString(entry.value);
        final result = await _engine.eval(wrapExtractorSource(entry.key, script));
        if (result.isError) {
          debugPrint('[quickjs] extractor ${entry.key} failed: ${result.value}');
        }
      } catch (error) {
        debugPrint('[quickjs] extractor ${entry.key} unavailable: $error');
      }
    }
    _extractorsLoaded = true;
  }

  Future<dynamic> call(
    SourceManifest source,
    String method,
    List<Object?> arguments, {
    Duration timeout = _maxCallTime,
    CancelToken? cancelToken,
  }) async {
    await ensureProviderLoaded(source, cancelToken: cancelToken);
    final sourceId = _runtimeSourceId(source);
    return _serialized(() async {
      _activeCancelToken = cancelToken;
      try {
      await _engine.ready;
      final argsJson = jsonEncode(arguments);
      final expression = '__callProviderT('
          '${jsonEncode(sourceId)}, ${jsonEncode(method)}, '
          '${jsonEncode(argsJson)}, ${timeout.inMilliseconds})';
      final result = await _engine
          .callAsync(expression, timeout + const Duration(seconds: 3))
          .timeout(timeout + const Duration(seconds: 4));
      if (result.isError) {
        throw JsRuntimeException(_unquote(result.value));
      }
      final value = _unquote(result.value);
      if (value.isEmpty || value == 'null') return null;
      try {
        return jsonDecode(value);
      } on FormatException {
        return value;
      }
      } finally {
        _activeCancelToken = null;
      }
    });
  }


  /// Extracts a supported hoster embed using the same QuickJS extractor
  /// registry used by Zangetsu provider scripts. Returns raw VideoSource maps.
  Future<dynamic> extractVideo(
    String url, {
    Map<String, dynamic> options = const <String, dynamic>{},
    Duration timeout = const Duration(seconds: 25),
    CancelToken? cancelToken,
  }) async {
    _validateHttpUrl(url);
    return _serialized(() async {
      _activeCancelToken = cancelToken;
      try {
      await _engine.ready;
      await _loadBundledExtractors();
      final expression = '__callExtractorT('
          '${jsonEncode(url)}, ${jsonEncode(jsonEncode(options))}, '
          '${timeout.inMilliseconds})';
      final result = await _engine
          .callAsync(expression, timeout + const Duration(seconds: 3))
          .timeout(timeout + const Duration(seconds: 4));
      if (result.isError) throw JsRuntimeException(_unquote(result.value));
      final value = _unquote(result.value);
      if (value.isEmpty || value == 'null') return const <dynamic>[];
      try {
        return jsonDecode(value);
      } on FormatException {
        throw const FormatException('Host extractor returned invalid JSON.');
      }
      } finally {
        _activeCancelToken = null;
      }
    });
  }

  String _unquote(String value) {
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is String) return decoded;
      } catch (_) {}
    }
    return value;
  }

  void _onChannel(String channel, dynamic raw) {
    switch (channel) {
      case 'fetch':
        unawaited(_onFetch(raw));
      case 'crypto':
        _onCrypto(raw);
      case 'timer':
        _onTimer(raw);
      case 'console':
        _onConsole(raw);
    }
  }

  Map<String, dynamic> _payloadMap(dynamic raw) {
    if (raw is String) return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    if (raw is Map) return Map<String, dynamic>.from(raw);
    throw const FormatException('Invalid JavaScript bridge payload.');
  }

  Future<void> _onFetch(dynamic raw) async {
    String? id;
    try {
      final payload = _payloadMap(raw);
      id = payload['id']?.toString();
      final url = payload['url']?.toString() ?? '';
      _validateHttpUrl(url);
      final method = (payload['method'] ?? 'GET').toString().toUpperCase();
      if (!const <String>{'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'}.contains(method)) {
        throw const FormatException('Provider requested a disallowed HTTP method.');
      }
      final rawHeaders = payload['headers'];
      final headers = rawHeaders is Map
          ? rawHeaders.map((key, value) => MapEntry(key.toString(), value.toString()))
          : <String, String>{};
      final body = payload['body'];
      final requestedTimeout = (payload['timeoutMs'] as num?)?.toInt() ?? 0;
      final timeoutMs = requestedTimeout <= 0
          ? 25000
          : requestedTimeout.clamp(1000, 25000).toInt();
      final response = await _dio.request<dynamic>(
        url,
        data: body,
        cancelToken: _activeCancelToken,
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.plain,
          followRedirects: payload['followRedirects'] != false,
          maxRedirects: 5,
          receiveTimeout: Duration(milliseconds: timeoutMs),
          sendTimeout: Duration(milliseconds: timeoutMs),
          validateStatus: (_) => true,
        ),
      );
      // Do not expose a response reached through a redirect to a private or
      // local destination to extension JavaScript.
      _validateHttpUrl(response.realUri.toString());
      final data = response.data?.toString() ?? '';
      if (utf8.encode(data).length > _maxResponseBytes) {
        throw const FormatException('Provider response exceeds the 8 MB safety limit.');
      }
      final responsePayload = <String, dynamic>{
        'status': response.statusCode ?? 0,
        'statusText': response.statusMessage ?? '',
        'headers': <String, String>{
          for (final entry in response.headers.map.entries)
            entry.key: entry.value.join(', '),
        },
        'url': response.realUri.toString(),
        'body': data,
      };
      _engine.post('__resolveFetch(${jsonEncode(id)}, ${jsonEncode(jsonEncode(responsePayload))});');
    } catch (error) {
      if (id != null) {
        _engine.post('__rejectFetch(${jsonEncode(id)}, ${jsonEncode(error.toString())});');
      }
    }
  }

  void _onCrypto(dynamic raw) {
    String? id;
    try {
      final payload = _payloadMap(raw);
      id = payload['id']?.toString();
      final operation = payload['op']?.toString();
      late final String value;
      if (operation == 'sha256') {
        value = sha256Hex(payload['message']?.toString() ?? '');
      } else if (operation == 'aesCtrDecrypt') {
        value = aesCtrDecryptToString(
          keyHex: payload['keyHex']?.toString() ?? '',
          counterHex: payload['counterHex']?.toString() ?? '',
          data: Uint8List.fromList(base64Decode(payload['dataB64']?.toString() ?? '')),
        );
      } else {
        throw FormatException('Unsupported provider crypto operation: $operation');
      }
      _engine.post('__resolveCrypto(${jsonEncode(id)}, ${jsonEncode(value)});');
    } catch (error) {
      if (id != null) {
        _engine.post('__rejectCrypto(${jsonEncode(id)}, ${jsonEncode(error.toString())});');
      }
    }
  }

  void _onTimer(dynamic raw) {
    try {
      final payload = _payloadMap(raw);
      final id = payload['id']?.toString();
      final ms = (payload['ms'] as num?)?.toInt() ?? 0;
      if (id == null) return;
      Future<void>.delayed(Duration(milliseconds: ms.clamp(0, 60000).toInt()), () {
        if (!_disposed) _engine.post('__fireTimer(${jsonEncode(id)});');
      });
    } catch (_) {}
  }

  void _onConsole(dynamic raw) {
    try {
      final payload = _payloadMap(raw);
      final source = (payload['__src'] ?? '?').toString();
      final level = (payload['level'] ?? 'log').toString();
      final message = (payload['message'] ?? '').toString();
      debugPrint('[$source/js $level] $message');
    } catch (_) {}
  }

  void _validateHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.host == 'localhost' ||
        uri.host.endsWith('.localhost') ||
        uri.host.endsWith('.local')) {
      throw const FormatException('Source URL must be a public HTTP(S) address.');
    }
    if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
      throw const FormatException('Source URL contains an invalid port.');
    }
    final ip = InternetAddress.tryParse(uri.host);
    if (ip != null && (ip.isLoopback || ip.isLinkLocal || ip.isMulticast || _isPrivateIp(ip))) {
      throw const FormatException('Private network addresses are not allowed for source scripts.');
    }
  }

  bool _isPrivateIp(InternetAddress address) {
    final parts = address.address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    final a = parts[0]!;
    final b = parts[1]!;
    return a == 10 ||
        a == 127 ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 0);
  }

  String _runtimeSourceId(SourceManifest source) {
    final value = source.id.trim();
    if (value.isEmpty || !RegExp(r'^[A-Za-z0-9._-]{1,80}$').hasMatch(value)) {
      throw const FormatException('Provider ID contains unsupported characters.');
    }
    // Zangetsu providers commonly derive platform variants from their IDs
    // (for example *_pv / *_hs). Keep the original ID prefix but namespace
    // each repository entry to prevent collisions between different repos.
    final namespace = sha256Hex('${source.stableKey}|${source.version}|${source.engine.endpoint}').substring(0, 16);
    return '${value}_$namespace';
  }

  void dispose() {
    _disposed = true;
    _engine.dispose();
  }
}
