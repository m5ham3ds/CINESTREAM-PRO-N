class RegularVideoLinks {
  String? url;
  String? quality;
  String? server;
  bool? isM3U8;
  bool? isDash;
  Map<String, String>? headers;
  String? sizeToken;
  String? providerCode;
  DateTime? expiresAt;
  bool isAdaptive;
  List<int> availableHeights;

  RegularVideoLinks({
    this.url,
    this.quality = 'unknown quality',
    this.server,
    this.isM3U8,
    this.isDash,
    this.headers,
    this.sizeToken,
    this.providerCode,
    this.expiresAt,
    this.isAdaptive = false,
    this.availableHeights = const <int>[],
  });

  RegularVideoLinks.fromJson(Map<String, dynamic> json)
      : url = json['url']?.toString(),
        server = json['server']?.toString(),
        quality = json['quality']?.toString() ?? 'unknown quality',
        isM3U8 = json['isM3U8'] == true,
        isDash = json['isDASH'] == true,
        sizeToken = json['sizeToken']?.toString(),
        providerCode = json['providerCode']?.toString(),
        expiresAt = DateTime.tryParse(json['expiresAt']?.toString() ?? ''),
        isAdaptive = json['isAdaptive'] == true,
        availableHeights = (json['availableHeights'] is List)
            ? (json['availableHeights'] as List)
                .map((value) => int.tryParse(value.toString()))
                .whereType<int>()
                .where((height) => height > 0)
                .toSet()
                .toList(growable: false)
            : const <int>[] {
    final rawHeaders = json['headers'];
    if (rawHeaders is Map) {
      headers = <String, String>{
        for (final entry in rawHeaders.entries)
          if (entry.value != null)
            entry.key.toString(): entry.value.toString(),
      };
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (url != null) 'url': url,
        if (quality != null) 'quality': quality,
        if (server != null) 'server': server,
        if (isM3U8 == true) 'isM3U8': true,
        if (isDash == true) 'isDASH': true,
        if (headers?.isNotEmpty == true) 'headers': headers,
        if (sizeToken != null) 'sizeToken': sizeToken,
        if (providerCode != null) 'providerCode': providerCode,
        if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
        if (isAdaptive) 'isAdaptive': true,
        if (availableHeights.isNotEmpty) 'availableHeights': availableHeights,
      };

  RegularVideoLinks copyWith({
    String? providerCode,
    String? server,
  }) =>
      RegularVideoLinks(
        url: url,
        quality: quality,
        server: server ?? this.server,
        isM3U8: isM3U8,
        isDash: isDash,
        headers: headers == null ? null : Map<String, String>.of(headers!),
        sizeToken: sizeToken,
        providerCode: providerCode ?? this.providerCode,
        expiresAt: expiresAt,
        isAdaptive: isAdaptive,
        availableHeights: List<int>.unmodifiable(availableHeights),
      );
}

/// The normalized result returned by every in-app stream provider.
///
/// Keeping this independent of a specific provider lets the player use direct
/// sources (such as VixSrc) and scraper API sources through the same contract.
class ProviderLoadResult {
  const ProviderLoadResult({
    this.videoLinks,
    this.subtitleLinks,
    this.success = false,
    this.errorMessage,
  });

  final List<RegularVideoLinks>? videoLinks;
  final List<RegularSubtitleLinks>? subtitleLinks;
  final bool success;
  final String? errorMessage;
}

class RegularSubtitleLinks {
  String? url;
  String? language;
  Map<String, String>? headers;

  RegularSubtitleLinks({this.language, this.url, this.headers});

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (language != null) 'language': language,
        if (url != null) 'url': url,
        if (headers?.isNotEmpty == true) 'headers': headers,
      };

  RegularSubtitleLinks.fromJson(Map<String, dynamic> json) {
    url = json['url'] ?? json['file'];
    language = json['lang'] ?? json['label'];
    final rawHeaders = json['headers'];
    if (rawHeaders is Map) {
      headers = {
        for (final entry in rawHeaders.entries)
          if (entry.value is String)
            entry.key.toString(): entry.value as String,
      };
    }
  }
}

/// Dramacool/Viewasian provider

/// Dramacool/Viewasian search
class DCVASearch {
  int? currentPage;
  bool? hasNextPage;
  List<DCVASearchEntry>? results;

  DCVASearch.fromJson(Map<String, dynamic> json) {
    currentPage = json['currentPage'];
    hasNextPage = json['hasNextPage'];
    if (json['results'] != null) {
      results = [];
      json['results'].forEach((v) {
        results!.add(DCVASearchEntry.fromJson(v));
      });
    }
  }
}

class DCVASearchEntry {
  DCVASearchEntry({
    required this.id,
    required this.title,
  });

  String? id;
  String? title;

  DCVASearchEntry.fromJson(Map<String, dynamic> json) {
    id = json['id'];
    title = json['title'];
  }
}

class DCVAInfo {
  String? id;
  String? title;
  String? releaseDate;
  String? message;
  List<DCVAInfoEntries>? episodes;

  DCVAInfo.fromJson(Map<String, dynamic> json) {
    id = json['id'];
    title = json['title'];
    releaseDate = json['releaseDate'];
    if (json.containsKey('message')) {
      message = json['message'];
    }
    if (json['episodes'] != null) {
      episodes = [];
      json['episodes'].forEach((v) {
        episodes!.add(DCVAInfoEntries.fromJson(v));
      });
    }
  }
}

class DCVAInfoEntries {
  String? id;
  String? title;
  String? url;
  String? subType;
  String? episode;

  DCVAInfoEntries.fromJson(Map<String, dynamic> json) {
    id = json['id'];
    title = json['title'];
    url = json['url'];
    episode = json['episode'].toString();
    subType = json['subType'];
  }
}

class DCVAStreamSources {
  DCVAStreamSources(
      {required this.videoLinks,
      required this.videoSubtitles,
      required this.messageExists});

  List<DCVAVideoLinks>? videoLinks;
  List<DCVASubLinks>? videoSubtitles;

  bool? messageExists;

  DCVAStreamSources.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('sources') && json['sources'] != null) {
      videoLinks = [];
      json['sources'].forEach((v) {
        videoLinks!.add(DCVAVideoLinks.fromJson(v));
      });
    }
    if (json.containsKey('subtitles') && json['subtitles'] != null) {
      videoSubtitles = [];
      json['subtitles'].forEach((v) {
        videoSubtitles!.add(DCVASubLinks.fromJson(v));
      });
    }
    if (json.containsKey('message')) {
      messageExists = true;
    }
  }
}

class DCVAVideoLinks extends RegularVideoLinks {
  DCVAVideoLinks.fromJson(super.json) : super.fromJson();
}

class DCVASubLinks extends RegularSubtitleLinks {
  DCVASubLinks.fromJson(super.json) : super.fromJson();
}
