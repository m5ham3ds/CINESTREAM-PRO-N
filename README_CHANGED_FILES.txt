CINESTREAM-PRO-N — Phase 22: FlixQuest original player transplant + CineStream data bridge

The player implementation was rebuilt from the original app-side FlixQuest player.dart and player support directory as the base. CineStream's existing provider/quality/cache/subtitle bridge was then reapplied without replacing provider engines, loaders, resolver/adapters, or source extraction.

Restored the FlixQuest native HD control in its original mobile Material control-row position. The CineStream all-provider quality catalog remains a separate overflow action. The extra Quality tile previously inserted into the portrait Watch Actions row was removed, restoring the original FlixQuest page-action order. The Audio & Subtitles action continues to use CineStream's subtitle sheet so SubSource priority, Arabic defaults, external subtitle search, upload, and timing remain available. Movie Material controls and the existing series/anime TV controls follow Phase 17.

CineStream-only support logic was retained in four player helper files:
- player_background_save.dart: guard Crashlytics calls when Firebase is disabled.
- player_episode_selection.dart: preserve anime classification during episode navigation.
- player_external_subtitles.dart: preserve subtitle cache, preferred-language selection, and external subtitle sources.
- player_movie_recommendations.dart: preserve originalLanguage metadata.

Twelve other player support files are byte-identical to the files in the uploaded FlixQuest archive. The source bridge continues to pass the scan snapshot/session, cached provider results, initial stream URL, provider-owned links, headers/formats, subtitle links, and quality catalog to the original player layer.

No provider engine, movie/TV loader, Unified/Legacy adapter, source parser, quality scanner, cache service, dependency manifest, or previous phase report was changed. Phase reports 1–21 remain intact. The new report exists in both the project root and phases/.

Verification: static source and archive checks only. Flutter/Dart SDK is not installed here, so no dart format/analyze/test or Android Release build is claimed. The FlixQuest archive points to the sibling dependency ../flixquest-betterplayer, which is not included in the uploaded archive; CineStream's existing Git dependency is retained to avoid the Phase 19 API mismatch.
