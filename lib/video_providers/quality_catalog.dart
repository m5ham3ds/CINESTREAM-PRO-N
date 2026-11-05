import 'common.dart';
import '../functions/video_utils.dart';

/// A concrete stream option shown by the app-wide quality picker.
///
/// Each entry keeps its owning provider and original link metadata. Two
/// providers offering the same resolution remain two independent choices.
class QualityCatalogEntry {
  const QualityCatalogEntry({
    required this.providerCode,
    required this.link,
    required this.height,
    required this.qualityLabel,
    this.adaptiveTargetHeight,
    this.isAdaptive = false,
  });

  final String providerCode;
  final RegularVideoLinks link;
  final int? height;
  final String qualityLabel;
  /// Null represents Auto; a number represents a user-selectable variant of
  /// this adaptive master URL.
  final int? adaptiveTargetHeight;
  final bool isAdaptive;
}

/// Builds a quality catalogue from all provider results without changing the
/// active player's data source. This is deliberately separate from the
/// BetterPlayer `resolutions` map, which belongs only to the currently active
/// URL/provider and cannot be safely mutated during background discovery.
abstract final class PlaybackQualityCatalog {
  static List<QualityCatalogEntry> collect({
    required Map<String, List<RegularVideoLinks>> linksByProvider,
    DateTime? now,
  }) {
    final checkedAt = now ?? DateTime.now();
    final result = <QualityCatalogEntry>[];
    final seen = <String>{};

    for (final providerEntry in linksByProvider.entries) {
      // Do not discard the aggregate bucket wholesale: Unified Sources can
      // itself be the actual provider that owns Jett/Sova/Phoenix results.
      // The aggregate bucket may also mirror links from other providers, so
      // exact owner+URL+metadata signatures below remove only those copies.
      for (final link in providerEntry.value) {
        final url = link.url?.trim();
        if (url == null || url.isEmpty) continue;
        if (link.expiresAt != null && !link.expiresAt!.isAfter(checkedAt)) {
          continue;
        }

        final declaredProviderCode = link.providerCode?.trim();
        final providerCode = declaredProviderCode?.isNotEmpty == true
            ? declaredProviderCode!
            : providerEntry.key;
        final headers = (link.headers ?? const <String, String>{}).entries.toList()
          ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
        final headerSignature = headers
            .map((entry) => '${entry.key.toLowerCase()}:${entry.value}')
            .join('|');
        final sortedAvailableHeights = link.availableHeights.toSet().toList()
          ..sort();
        final signature = <String>[
          providerCode,
          url,
          link.quality ?? '',
          link.isM3U8 == true ? 'hls' : '',
          link.isDash == true ? 'dash' : '',
          link.isAdaptive ? 'adaptive' : '',
          headerSignature,
          sortedAvailableHeights.join(','),
        ].join('\u001f');
        if (!seen.add(signature)) continue;

        final availableHeights = link.availableHeights
            .where((height) => height > 0)
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));
        final parsedHeight = VideoUtils.videoQualityHeight(link.quality ?? '');
        final rawQuality = link.quality?.trim();
        final normalizedQuality = (rawQuality ?? '').trim().toLowerCase();
        final adaptiveLabel = normalizedQuality.startsWith('auto') ||
            normalizedQuality.startsWith('adaptive') ||
            normalizedQuality.startsWith('master');
        if (link.isAdaptive || availableHeights.isNotEmpty || adaptiveLabel) {
          // An adaptive master is not one quality. Expose Auto and every
          // representation discovered from provider metadata or its manifest
          // as independent choices, all retaining the same URL/headers.
          result.add(QualityCatalogEntry(
            providerCode: providerCode,
            link: link,
            height: null,
            qualityLabel: 'Auto',
            isAdaptive: true,
          ));
          final variantHeights = <int>{...availableHeights};
          if (parsedHeight != null) variantHeights.add(parsedHeight);
          final sortedVariants = variantHeights.toList()
            ..sort((a, b) => b.compareTo(a));
          for (final variantHeight in sortedVariants) {
            result.add(QualityCatalogEntry(
              providerCode: providerCode,
              link: link,
              height: variantHeight,
              qualityLabel: '${variantHeight}p',
              adaptiveTargetHeight: variantHeight,
              isAdaptive: true,
            ));
          }
        } else {
          result.add(QualityCatalogEntry(
            providerCode: providerCode,
            link: link,
            height: parsedHeight,
            qualityLabel: rawQuality == null || rawQuality.isEmpty
                ? 'Unknown quality'
                : rawQuality,
          ));
        }
      }
    }

    result.sort((left, right) {
      final leftHeight = left.height;
      final rightHeight = right.height;
      if (leftHeight != rightHeight) {
        if (leftHeight == null) return 1;
        if (rightHeight == null) return -1;
        return rightHeight.compareTo(leftHeight);
      }
      final qualityOrder = left.qualityLabel.compareTo(right.qualityLabel);
      if (qualityOrder != 0) return qualityOrder;
      final providerOrder = (left.link.server ?? left.providerCode)
          .compareTo(right.link.server ?? right.providerCode);
      if (providerOrder != 0) return providerOrder;
      return (left.link.url ?? '').compareTo(right.link.url ?? '');
    });
    return List<QualityCatalogEntry>.unmodifiable(result);
  }
}
