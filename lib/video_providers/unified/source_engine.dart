import 'package:dio/dio.dart';

import 'openstream_anime_engine.dart';
import 'openstream_web_embed_engine.dart';
import 'quickjs_source_engine.dart';
import 'quickjs/quickjs_provider_runtime.dart';

import 'media_identity.dart';
import 'source_manifest.dart';
import 'stremio_addon_provider.dart';
import 'stream_option.dart';
import 'vidking_direct_provider.dart';

class UnifiedSourceResult {
  const UnifiedSourceResult({
    this.streams = const <UnifiedStreamOption>[],
    this.errorMessage,
    this.elapsed,
  });

  final List<UnifiedStreamOption> streams;
  final String? errorMessage;
  final Duration? elapsed;

  bool get success => streams.any((stream) => stream.isPlayable);
}

abstract class SourceEngine {
  SourceEngineKind get kind;

  bool supports(SourceManifest source) => source.engine.kind == kind;

  Future<UnifiedSourceResult> resolve({
    required SourceManifest source,
    required MediaIdentity media,
    CancelToken? cancelToken,
  });
}

class VidkingDirectSourceEngine extends SourceEngine {
  VidkingDirectSourceEngine({VidkingDirectProvider? provider, Dio? dio})
      : _provider = provider ?? VidkingDirectProvider(dio: dio);

  final VidkingDirectProvider _provider;

  @override
  SourceEngineKind get kind => SourceEngineKind.vidkingDirect;

  @override
  Future<UnifiedSourceResult> resolve({
    required SourceManifest source,
    required MediaIdentity media,
    CancelToken? cancelToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final streams = await _provider.resolve(
        source: source,
        media: media,
        cancelToken: cancelToken,
      );
      stopwatch.stop();
      return UnifiedSourceResult(streams: streams, elapsed: stopwatch.elapsed);
    } on DioException catch (error) {
      stopwatch.stop();
      return UnifiedSourceResult(
        errorMessage: error.message ?? 'Vidking request failed.',
        elapsed: stopwatch.elapsed,
      );
    } on FormatException catch (error) {
      stopwatch.stop();
      return UnifiedSourceResult(
        errorMessage: error.message,
        elapsed: stopwatch.elapsed,
      );
    } catch (error) {
      stopwatch.stop();
      return UnifiedSourceResult(
        errorMessage: error.toString(),
        elapsed: stopwatch.elapsed,
      );
    }
  }
}

class StremioSourceEngine extends SourceEngine {
  StremioSourceEngine({StremioAddonProvider? provider})
      : _provider = provider ?? StremioAddonProvider();

  final StremioAddonProvider _provider;

  @override
  SourceEngineKind get kind => SourceEngineKind.stremio;

  @override
  Future<UnifiedSourceResult> resolve({
    required SourceManifest source,
    required MediaIdentity media,
    CancelToken? cancelToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final streams = await _provider.getStreams(
        source: source,
        media: media,
        cancelToken: cancelToken,
      );
      stopwatch.stop();
      return UnifiedSourceResult(streams: streams, elapsed: stopwatch.elapsed);
    } on DioException catch (error) {
      stopwatch.stop();
      return UnifiedSourceResult(
        errorMessage: error.message ?? 'Stremio add-on request failed.',
        elapsed: stopwatch.elapsed,
      );
    } on FormatException catch (error) {
      stopwatch.stop();
      return UnifiedSourceResult(
        errorMessage: error.message,
        elapsed: stopwatch.elapsed,
      );
    } catch (error) {
      stopwatch.stop();
      return UnifiedSourceResult(
        errorMessage: error.toString(),
        elapsed: stopwatch.elapsed,
      );
    }
  }
}

/// Resolves source manifests through registered engines. Unsupported engine
/// types remain visible in repository metadata but cannot accidentally run.
class UnifiedSourceAttempt {
  const UnifiedSourceAttempt({required this.source, required this.result});

  final SourceManifest source;
  final UnifiedSourceResult result;
}

typedef SourceAttemptCallback = void Function(UnifiedSourceAttempt attempt);

/// Called when a source actually leaves the queue and begins resolving.
typedef SourceEngineStartCallback = void Function(SourceManifest source);

class SourceEngineRegistry {
  SourceEngineRegistry({Iterable<SourceEngine> engines = const []}) {
    for (final engine in engines) {
      register(engine);
    }
  }

  factory SourceEngineRegistry.standard({Dio? dio}) {
    final quickJsRuntime = QuickJsProviderRuntime(dio: dio);
    return SourceEngineRegistry(
      engines: <SourceEngine>[
        VidkingDirectSourceEngine(dio: dio),
        StremioSourceEngine(provider: StremioAddonProvider(dio: dio)),
        OpenStreamWebEmbedSourceEngine(engineKind: SourceEngineKind.webEmbed, quickJsRuntime: quickJsRuntime, dio: dio),
        OpenStreamWebEmbedSourceEngine(engineKind: SourceEngineKind.vidkingWebView, quickJsRuntime: quickJsRuntime, dio: dio),
        OpenStreamAnimeSourceEngine(dio: dio, quickJsRuntime: quickJsRuntime),
        QuickJsSourceEngine(runtime: quickJsRuntime, dio: dio),
      ],
    );
  }

  final Map<SourceEngineKind, SourceEngine> _engines = {};

  void register(SourceEngine engine) {
    _engines[engine.kind] = engine;
  }

  bool supports(SourceManifest source) =>
      source.isRunnable && (_engines[source.engine.kind]?.supports(source) ?? false);

  /// Resolves enabled sources with bounded concurrency. The default is
  /// sequential: [onSourceStart] fires only when a source actually begins,
  /// and [onAttempt] fires when that source finishes. Results retain manifest
  /// priority order while the UI shows only active work as loading.
  Future<List<UnifiedSourceAttempt>> resolveMany({
    required Iterable<SourceManifest> sources,
    required MediaIdentity media,
    int maxConcurrency = 1,
    CancelToken? cancelToken,
    SourceAttemptCallback? onAttempt,
    SourceEngineStartCallback? onSourceStart,
  }) async {
    final ordered = sources.toList(growable: false)
      ..sort((a, b) {
        final byPriority = a.engine.priority.compareTo(b.engine.priority);
        return byPriority != 0 ? byPriority : a.stableKey.compareTo(b.stableKey);
      });
    if (ordered.isEmpty) return const <UnifiedSourceAttempt>[];

    final attempts = List<UnifiedSourceAttempt?>.filled(ordered.length, null);
    var nextIndex = 0;
    final workerCount = maxConcurrency.clamp(1, ordered.length).toInt();

    Future<void> worker() async {
      while (true) {
        if (cancelToken?.isCancelled == true) return;
        final index = nextIndex++;
        if (index >= ordered.length) return;
        final source = ordered[index];
        try {
          onSourceStart?.call(source);
        } catch (_) {
          // Progress reporting must not interrupt the source queue.
        }
        UnifiedSourceResult result;
        try {
          result = await resolve(
            source: source,
            media: media,
            cancelToken: cancelToken,
          );
        } catch (error) {
          result = UnifiedSourceResult(errorMessage: error.toString());
        }
        final attempt = UnifiedSourceAttempt(source: source, result: result);
        attempts[index] = attempt;
        try {
          onAttempt?.call(attempt);
        } catch (_) {
          // A UI callback must not abort remaining provider resolutions.
        }
      }
    }

    await Future.wait(List<Future<void>>.generate(workerCount, (_) => worker()));
    return attempts.whereType<UnifiedSourceAttempt>().toList(growable: false);
  }

  Future<UnifiedSourceResult> resolve({
    required SourceManifest source,
    required MediaIdentity media,
    CancelToken? cancelToken,
  }) async {
    final engine = _engines[source.engine.kind];
    if (!source.enabled) {
      return const UnifiedSourceResult(errorMessage: 'Source is disabled.');
    }
    if (source.status == 0) {
      return const UnifiedSourceResult(
        errorMessage: 'Source is marked down in its repository.',
      );
    }
    if (engine == null || !engine.supports(source)) {
      return UnifiedSourceResult(
        errorMessage:
            'Unsupported source engine: ${source.engine.rawType.isEmpty ? 'unknown' : source.engine.rawType}',
      );
    }
    return engine.resolve(
      source: source,
      media: media,
      cancelToken: cancelToken,
    );
  }
}
