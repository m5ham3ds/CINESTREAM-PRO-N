# PHASE 22 — FlixQuest original player transplant with CineStream playback bridge

## الهدف والنطاق

هذه المرحلة تنفّذ استبدال ملفات واجهة المشغّل بملفات FlixQuest الأصلية كأساس مباشر، ثم تعيد توصيل جسر بيانات CineStream فوقها. لا تستبدل هذه المرحلة محركات المصادر أو طريقة البحث والاستخراج أو موائم Unified-to-Legacy أو هوية المزوّد.

مصادر العمل المعتمدة:

- **مشروع التعديل:** أحدث نسخة CINESTREAM-PRO-N الموجودة في أرشيف Phase 21.
- **مرجع ملفات المشغّل والواجهة:** `flixquest-main.zip` الذي أعاد المستخدم رفعه.
- **مرجع سلوك البيانات والقيود:** ملفات `phases/` من أحدث نسخة CINESTREAM-PRO-N فقط.
- نسخة Phase 17 استُخدمت مرجعًا سابقًا لسلوك المصادر ولم تُستخدم مجلدات `phases/` الخاصة بها لتحديد التعديلات.

## 1. نقل ملفات FlixQuest الأصلية

بدأ استبدال `lib/screens/common/player.dart` بنسخة FlixQuest الأصلية، ثم أُعيد تطبيق طبقة CineStream الخاصة بالبيانات والتشغيل فوق هذا الأساس بدل إعادة إنشاء واجهة المشغّل.

تم نسخ محتويات `lib/screens/common/player/` من FlixQuest. الملفات التالية بقيت مطابقة بايتًا لنسخ FlixQuest:

- `player_completion_detector.dart`
- `player_data_management.dart`
- `player_feedback_ui.dart`
- `player_local_subtitles.dart`
- `player_next_episode_policy.dart`
- `player_preroll_ad.dart`
- `player_sheet_ui.dart`
- `player_strings.dart`
- `player_subtitle_timing_sheet.dart`
- `player_watch_page.dart`
- `stream_feedback_prompt.dart`
- `tv_subtitle_timing_panel.dart`

لم تُعدّل شاشات المشاهدة أو بنية صفحة الفيلم أو تخطيط Portrait/Fullscreen لإعادة رسم التصميم. استُخدمت ملفات FlixQuest الأصلية كقاعدة مباشرة.

## 2. جسر بيانات CineStream الذي أُعيد توصيله

أُبقيت إضافات CineStream الوظيفية داخل `PlayerOne` لأنها مطلوبة لتوصيل مخرجات محركات المصادر بالمشغّل الأصلي:

- تمرير `initialVideoLinks` و`initialSubtitleLinks` و`providerScanSession` و`cachedProviderResults` و`initialStreamUrl` من محمّلات الفيلم/الحلقة إلى المشغّل.
- استعادة لقطة نتائج الفحص المنجزة قبل إنشاء المشغّل، ثم الاشتراك في تحديثات الفحص اللاحقة حتى لا تضيع نتائج المزوّد السريع.
- الاحتفاظ بروابط كل مزوّد وهويته، واسم الخادم، والجودة، والرؤوس، والصيغة، وبيانات الحجم، والترجمات المرتبطة به.
- تجميع `PlaybackQualityCatalog` من جميع المزوّدين، بما في ذلك `unified:sources`، مع عدم دمج روابط خوادم مختلفة لمجرد تطابق الدقة.
- متابعة فحص HLS/DASH التكيفي وإضافة ارتفاعات الـmanifest إلى الكتالوج دون استدعاء `setupDataSource` أو تغيير الرابط النشط عند وصول نتيجة خلفية.
- إبقاء التبديل الفعلي للرابط أو المزوّد أو rendition مرتبطًا باختيار المستخدم أو بمسار استرداد فشل تشغيل حقيقي.
- الحفاظ على استعادة Playback Cache، وإبطال الرابط الفاشل فقط، ثم تجربة رابط بديل/تحديث المزوّد/الانتقال إلى مزوّد آخر وفق سياسة المراحل السابقة.
- تمرير ترجمات المزوّد المختار ورؤوسها إلى BetterPlayer، والحفاظ على SubSource كأولوية للترجمة العربية، واستعادة ملفات الترجمة الخارجية المحفوظة قبل تهيئة مصدر الفيديو.

لم يتم تغيير ملفات `lib/video_providers/` أو محمّلات الأفلام والمسلسلات أو موائم المصدر أو طبقة Unified. بقيت نقاط تسليم البيانات الحالية إلى `PlayerOne` كما هي.

## 3. استعادة شكل مشغل FlixQuest

- أُعيد إظهار زر HD الأصلي في موضعه من شريط Material على الهاتف، كما في FlixQuest.
- بقي كتالوج CineStream متعدد المزوّدين مدخلًا منفصلًا داخل Overflow؛ زر HD الأصلي يعرض جودة المصدر النشط، بينما مدخل CineStream يعرض كل الروابط والجودات المكتشفة.
- أزيل اختصار الجودة الذي كان مضافًا إلى قائمة Watch Actions في صفحة Portrait؛ لذلك لا يضيف هذا الإصدار زرًا جديدًا إلى صفحة المشاهدة الأصلية أو يغيّر ترتيب إجراءات FlixQuest.
- بقي استدعاء Audio & Subtitles متصلًا بنافذة CineStream المخصصة كي لا تضيع أولوية SubSource أو البحث الخارجي أو رفع ملفات الترجمة أو ضبط التوقيت.
- احتُفظ بقرار Phase 17: الأفلام تستخدم Material controls، بينما المسلسلات والأنمي تحتفظ بعناصر تحكم التلفاز الحالية.
- لم تُعد معاملات `fastHoldSpeed` أو `slowHoldSpeed` إلى `BetterPlayerGestureConfiguration`؛ فهي غير مدعومة في اعتماد Git الذي يستخدمه CineStream، وإعادتها ستعيد خطأ البناء الموثق في Phase 19.

## 4. ملفات دعم CineStream التي بقيت بإضافاتها الوظيفية

نُقلت بقية ملفات مجلد FlixQuest أولًا، ثم أُعيدت فقط الإضافات غير المرئية اللازمة لاستمرار وظائف CineStream في هذه الملفات الأربعة:

- `player_background_save.dart`: شرط `AppRuntime.firebaseEnabled` حتى لا يُستدعى Crashlytics عندما يكون Firebase معطلًا في البناء المحلي.
- `player_episode_selection.dart`: تمرير `isAnime` عند الانتقال إلى الحلقة التالية للحفاظ على تصنيف الأنمي.
- `player_external_subtitles.dart`: تخزين الترجمات الخارجية واستعادتها، والبحث متعدد المصادر، وأولوية اللغة المفضلة وSubSource، وعدم جعل البحث الخارجي يؤخر بدء الفيديو.
- `player_movie_recommendations.dart`: تمرير `originalLanguage` إلى بيانات الفيلم الموصى به.

هذه إضافات بيانات/سلوك وليست إعادة تصميم لشاشة تشغيل الفيلم.

## 5. ما لم يتغير

- `lib/video_providers/**` ومحركات الإضافات والتسجيل والـmanifest والمحللات.
- `lib/screens/movie/movie_video_loader.dart` و`lib/screens/tv/tv_video_loader.dart`.
- `lib/functions/video_utils.dart` وموائم Unified-to-Legacy.
- كتالوج الجودة، وفاحص HLS/DASH، وسياسة الاحتفاظ بكل الدقات، وهوية كل مزوّد.
- خدمة التخزين المؤقت للمصادر، واستعادة الرابط النشط، وسلسلة failover.
- خدمة SubSource/OpenSubtitles، وأولوية العربية، وتفضيلات الترجمة.
- مجلدات وتقارير المراحل 1–21؛ أُضيف تقرير Phase 22 فقط.
- `pubspec.yaml` و`pubspec.lock` وإعداد اعتماد BetterPlayer الحالي.

## 6. التحقق

تم تنفيذ فحوص ساكنة على الملفات والحزمة:

- مطابقة 12 ملف دعم من مجلد المشغّل بايتًا مع ملفات FlixQuest الأصلية.
- التحقق من أن ملفات الدعم الأربعة المتبقية تحتوي إضافات CineStream المذكورة أعلاه.
- التحقق من وجود حقول جسر البيانات المطلوبة في `PlayerOne` ومن استمرار تمريرها من محمّلات الفيلم والتلفاز.
- التحقق من بقاء إدخال كتالوج الجودة الموحد داخل Overflow مع زر HD الأصلي في شريط الهاتف، ومن إزالة اختصار الجودة الإضافي من Watch Actions حتى يبقى ترتيب صفحة FlixQuest الأصلية كما هو.
- التحقق من عدم وجود معاملات `fastHoldSpeed` و`slowHoldSpeed` في إنشاء `BetterPlayerGestureConfiguration`.
- التحقق من عدم تغير ملفات محركات المصادر أو محمّلات الفيلم/التلفاز أو إعدادات الاعتماد مقارنةً بأحدث نسخة Phase 21.
- التحقق من أن ZIP يحتوي مجلدًا أعلى باسم `CINESTREAM-PRO-N/` وأن اختبار سلامة ZIP لا يعيد أخطاء.

**حدود التحقق:** لم يتوفر Flutter أو Dart SDK في بيئة التحرير، لذلك لم يتم تشغيل `dart format` أو `flutter analyze` أو `flutter test` أو `assembleProdRelease`، ولم يُختبر البث فعليًا على جهاز. لا يُدّعى نجاح بناء APK قبل مرور GitHub Actions.

## 7. ملاحظة اعتماد BetterPlayer الخارجي

يستخدم `flixquest-main/pubspec.yaml` اعتماد `better_player_plus` بمسار شقيق `../flixquest-betterplayer`، لكن مجلد الاعتماد الشقيق نفسه غير موجود داخل `flixquest-main.zip` المرفوع. لذلك بقي اعتماد Git الموجود أصلًا في CineStream كما هو، التزامًا بتوافق Phase 19. جرى نقل ملفات التطبيق الأصلية المتاحة، لكن لم تُستبدل شفرة مكتبة BetterPlayer الخارجية غير المرفقة.

إذا استمر اختلاف رسومات داخلية مصدرها المكتبة نفسها بعد تجربة هذا الإصدار، فإن المقارنة الحرفية لتلك الرسومات تتطلب أرشيف مجلد `flixquest-betterplayer` الشقيق؛ لا ينبغي تغيير API أو تثبيت إصدار بديل بالتخمين.

## سياسة المراحل

Phase 22 تقرير مستقل. تقارير Phase 1–21 محفوظة دون إعادة كتابة أو حذف. يجب أن تبقى محركات المصادر وجسر البيانات والميزات الموثقة أعلاه محفوظة في التعديلات اللاحقة.
