import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../video_providers/common.dart';
import '../video_providers/unified/media_identity.dart';

abstract interface class PlaybackCacheVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecurePlaybackCacheVault implements PlaybackCacheVault {
  SecurePlaybackCacheVault({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class CachedProviderStreams {
  const CachedProviderStreams({
    required this.providerCode,
    required this.providerName,
    required this.videoLinks,
    this.subtitleLinks = const <RegularSubtitleLinks>[],
    this.resolvedAtByUrl = const <String, DateTime>{},
  });

  final String providerCode;
  final String providerName;
  final List<RegularVideoLinks> videoLinks;
  final List<RegularSubtitleLinks> subtitleLinks;
  /// Per-link discovery time. Updating another provider must never refresh the
  /// lifetime of an older signed URL.
  final Map<String, DateTime> resolvedAtByUrl;

  ProviderLoadResult toLoadResult() => ProviderLoadResult(
        success: videoLinks.isNotEmpty,
        videoLinks: videoLinks,
        subtitleLinks: subtitleLinks,
        errorMessage: videoLinks.isEmpty ? 'Cached stream is unavailable.' : null,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'providerCode': providerCode,
        'providerName': providerName,
        'videoLinks': videoLinks.map((link) => link.toJson()).toList(),
        'resolvedAtByUrl': <String, String>{
          for (final entry in resolvedAtByUrl.entries)
            entry.key: entry.value.toUtc().toIso8601String(),
        },
        'subtitleLinks':
            subtitleLinks.map((subtitle) => subtitle.toJson()).toList(),
      };

  factory CachedProviderStreams.fromJson(
    Map<String, dynamic> json, {
    required DateTime legacySavedAt,
    required DateTime now,
    required Duration maxAge,
  }) {
    final rawLinks = json['videoLinks'];
    final rawSubtitles = json['subtitleLinks'];
    final rawResolvedAt = json['resolvedAtByUrl'];
    final resolvedAt = <String, DateTime>{};
    if (rawResolvedAt is Map) {
      for (final entry in rawResolvedAt.entries) {
        final parsed = DateTime.tryParse(entry.value?.toString() ?? '');
        if (parsed != null) resolvedAt[entry.key.toString()] = parsed;
      }
    }
    final links = <RegularVideoLinks>[];
    if (rawLinks is List) {
      for (final item in rawLinks.whereType<Map>()) {
        final link = RegularVideoLinks.fromJson(Map<String, dynamic>.from(item));
        final url = link.url?.trim();
        if (url == null || url.isEmpty) continue;
        // Version 1 caches did not track per-link discovery time. Their
        // original entry timestamp is used once, never refreshed on migration.
        final discoveredAt = resolvedAt[url] ?? legacySavedAt;
        final age = now.difference(discoveredAt);
        if (age.isNegative || age > maxAge || !_usableLink(link, now: now)) {
          continue;
        }
        resolvedAt[url] = discoveredAt;
        links.add(link);
      }
    }
    final subtitles = rawSubtitles is List
        ? rawSubtitles
            .whereType<Map>()
            .map((item) => RegularSubtitleLinks.fromJson(
                  Map<String, dynamic>.from(item),
                ))
            .where((subtitle) => subtitle.url?.trim().isNotEmpty == true)
            .toList(growable: false)
        : const <RegularSubtitleLinks>[];
    return CachedProviderStreams(
      providerCode: json['providerCode']?.toString() ?? '',
      providerName: json['providerName']?.toString() ?? '',
      videoLinks: links,
      subtitleLinks: subtitles,
      resolvedAtByUrl: Map<String, DateTime>.unmodifiable(resolvedAt),
    );
  }
}

class PlaybackStreamCacheEntry {
  const PlaybackStreamCacheEntry({
    required this.savedAt,
    required this.lastProviderCode,
    required this.lastUrl,
    required this.providers,
  });

  final DateTime savedAt;
  final String lastProviderCode;
  final String lastUrl;
  final Map<String, CachedProviderStreams> providers;

  CachedProviderStreams? get lastProvider => providers[lastProviderCode];

  Map<String, ProviderLoadResult> get providerResults => <String, ProviderLoadResult>{
        for (final entry in providers.entries)
          entry.key: entry.value.toLoadResult(),
      };
}

/// Persists resolved stream references and the last URL that actually reached
/// the player's initialized state. Signed URLs and request headers are kept in
/// platform secure storage, not ordinary preferences or diagnostic logs.
class PlaybackStreamCacheStore {
  PlaybackStreamCacheStore({
    PlaybackCacheVault? vault,
    DateTime Function()? clock,
    this.maxAge = const Duration(hours: 24),
  })  : _vault = vault ?? SecurePlaybackCacheVault(),
        _clock = clock ?? DateTime.now;

  static const String _keyPrefix = 'flixquest.playback_stream_cache.v1.';
  final PlaybackCacheVault _vault;
  final DateTime Function() _clock;
  final Duration maxAge;

  String _storageKey(MediaIdentity identity) {
    final digest = sha256.convert(utf8.encode(identity.playbackCacheKey));
    return '$_keyPrefix$digest';
  }

  Future<PlaybackStreamCacheEntry?> read(MediaIdentity identity) async {
    final key = _storageKey(identity);
    final raw = await _vault.read(key);
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('Invalid playback cache.');
      final savedAt = DateTime.tryParse(decoded['savedAt']?.toString() ?? '');
      if (savedAt == null) throw const FormatException('Cache timestamp is missing.');
      final now = _clock();
      final rawProviders = decoded['providers'];
      if (rawProviders is! List) throw const FormatException('Cache sources are missing.');
      final providers = <String, CachedProviderStreams>{};
      for (final item in rawProviders.whereType<Map>()) {
        final provider = CachedProviderStreams.fromJson(
          Map<String, dynamic>.from(item),
          legacySavedAt: savedAt,
          now: now,
          maxAge: maxAge,
        );
        if (provider.providerCode.isNotEmpty && provider.videoLinks.isNotEmpty) {
          providers[provider.providerCode] = provider;
        }
      }
      if (providers.isEmpty) {
        await _vault.delete(key);
        return null;
      }

      var lastProviderCode = decoded['lastProviderCode']?.toString() ?? '';
      var lastUrl = decoded['lastUrl']?.toString() ?? '';
      var lastProvider = providers[lastProviderCode];
      if (lastProvider == null) {
        lastProviderCode = providers.keys.first;
        lastProvider = providers[lastProviderCode];
      }
      if (lastProvider == null) return null;
      if (!lastProvider.videoLinks.any((link) => link.url == lastUrl)) {
        lastUrl = lastProvider.videoLinks.first.url ?? '';
      }
      if (lastUrl.isEmpty) return null;

      return PlaybackStreamCacheEntry(
        savedAt: savedAt,
        lastProviderCode: lastProviderCode,
        lastUrl: lastUrl,
        providers: Map<String, CachedProviderStreams>.unmodifiable(providers),
      );
    } catch (_) {
      await _vault.delete(key);
      return null;
    }
  }

  Future<void> save({
    required MediaIdentity identity,
    required Map<String, CachedProviderStreams> providers,
    required String? lastProviderCode,
    required String? lastUrl,
  }) async {
    final now = _clock();
    final storageKey = _storageKey(identity);
    final existingResolvedAt = <String, Map<String, DateTime>>{};
    DateTime? legacySavedAt;
    // Preserve each URL's original discovery time when new providers or
    // qualities arrive. This prevents background updates from extending the
    // life of old signed URLs.
    final previousRaw = await _vault.read(storageKey);
    if (previousRaw != null && previousRaw.trim().isNotEmpty) {
      try {
        final previous = jsonDecode(previousRaw);
        final rawPreviousProviders =
            previous is Map ? previous['providers'] : null;
        if (previous is Map) {
          legacySavedAt = DateTime.tryParse(
            previous['savedAt']?.toString() ?? '',
          );
        }
        if (rawPreviousProviders is List) {
          for (final item in rawPreviousProviders.whereType<Map>()) {
            final code = item['providerCode']?.toString() ?? '';
            final rawTimes = item['resolvedAtByUrl'];
            final times = <String, DateTime>{};
            if (rawTimes is Map) {
              for (final entry in rawTimes.entries) {
                final parsed = DateTime.tryParse(entry.value?.toString() ?? '');
                if (parsed != null) times[entry.key.toString()] = parsed;
              }
            }
            // One-time migration for the previous whole-entry timestamp.
            final rawLinks = item['videoLinks'];
            if (rawLinks is List && legacySavedAt != null) {
              for (final rawLink in rawLinks.whereType<Map>()) {
                final url = rawLink['url']?.toString().trim();
                if (url != null && url.isNotEmpty) {
                  times.putIfAbsent(url, () => legacySavedAt!);
                }
              }
            }
            existingResolvedAt[code] = times;
          }
        }
      } catch (_) {
        // A corrupt old entry must not prevent saving fresh valid streams.
      }
    }

    final usableProviders = <CachedProviderStreams>[];
    for (final entry in providers.entries) {
      final links = <RegularVideoLinks>[];
      final resolvedAt = <String, DateTime>{};
      for (final link in entry.value.videoLinks) {
        if (!_usableLink(link, now: now)) continue;
        final url = link.url!.trim();
        final discoveredAt =
            existingResolvedAt[entry.key]?[url] ?? now;
        final age = now.difference(discoveredAt);
        if (age.isNegative || age > maxAge) continue;
        links.add(link.copyWith(providerCode: entry.key));
        resolvedAt[url] = discoveredAt;
      }
      if (links.isEmpty) continue;
      usableProviders.add(CachedProviderStreams(
        providerCode: entry.key,
        providerName: entry.value.providerName,
        videoLinks: links,
        subtitleLinks: entry.value.subtitleLinks,
        resolvedAtByUrl: Map<String, DateTime>.unmodifiable(resolvedAt),
      ));
    }
    if (usableProviders.isEmpty) return;

    var providerCode = lastProviderCode ?? '';
    var url = lastUrl ?? '';
    CachedProviderStreams? selected;
    for (final item in usableProviders) {
      if (item.providerCode == providerCode) {
        selected = item;
        break;
      }
    }
    if (selected == null) {
      providerCode = usableProviders.first.providerCode;
      url = usableProviders.first.videoLinks.first.url ?? '';
    } else if (!selected.videoLinks.any((link) => link.url == url)) {
      url = selected.videoLinks.first.url ?? '';
    }
    if (providerCode.isEmpty || url.isEmpty) return;

    final payload = <String, dynamic>{
      'version': 2,
      'savedAt': now.toUtc().toIso8601String(),
      'lastProviderCode': providerCode,
      'lastUrl': url,
      'providers': usableProviders.map((item) => item.toJson()).toList(),
    };
    await _vault.write(storageKey, jsonEncode(payload));
  }

  Future<void> invalidateUrl({
    required MediaIdentity identity,
    required String providerCode,
    required String url,
  }) async {
    final entry = await read(identity);
    if (entry == null) return;
    final next = <String, CachedProviderStreams>{};
    for (final value in entry.providers.values) {
      final links = value.videoLinks
          .where((link) =>
              !(value.providerCode == providerCode && link.url == url))
          .toList(growable: false);
      if (links.isNotEmpty) {
        next[value.providerCode] = CachedProviderStreams(
          providerCode: value.providerCode,
          providerName: value.providerName,
          videoLinks: links,
          subtitleLinks: value.subtitleLinks,
          resolvedAtByUrl: <String, DateTime>{
            for (final link in links)
              if (link.url != null &&
                  value.resolvedAtByUrl.containsKey(link.url))
                link.url!: value.resolvedAtByUrl[link.url]!,
          },
        );
      }
    }
    if (next.isEmpty) {
      await _vault.delete(_storageKey(identity));
      return;
    }
    final lastProvider = next[entry.lastProviderCode] ?? next.values.first;
    final lastUrl = lastProvider.videoLinks.first.url ?? '';
    await save(
      identity: identity,
      providers: next,
      lastProviderCode: lastProvider.providerCode,
      lastUrl: lastUrl,
    );
  }
}

bool _usableLink(RegularVideoLinks link, {DateTime? now}) {
  final url = link.url?.trim();
  final uri = Uri.tryParse(url ?? '');
  return url != null &&
      url.isNotEmpty &&
      uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (link.expiresAt == null || link.expiresAt!.isAfter(now ?? DateTime.now()));
}
