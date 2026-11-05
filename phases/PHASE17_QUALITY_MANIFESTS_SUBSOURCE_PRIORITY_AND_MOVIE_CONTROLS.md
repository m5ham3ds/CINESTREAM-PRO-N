# Phase 17 — Quality manifests, SubSource priority, and movie controls

## الهدف

إصلاح ثلاثة مسارات مترابطة ظهرت في اختبارات المستخدم:

1. ظهور أسماء مزوّدي الفيديو دون تحويل كل دقات HLS/DASH إلى خيارات قابلة للاختيار في قائمة Quality.
2. ضمان تجربة SubSource أولًا عند البحث عن ترجمة عربية، مع الانتقال إلى بقية المزوّدين فقط عند غياب نتيجة صالحة أو فشل تنزيلها.
3. إعادة تخطيط عناصر التحكم للأفلام إلى شريط FlixQuest Material ذي الأزرار النصية، دون تغيير عناصر التحكم الصحيحة للمسلسلات والأنمي.

## نتائج التحقيق وأسباب المشكلة

### أ. فقدان بيانات الدقة قبل وصولها إلى المشغّل

- Scraper API كان يقرأ `isDASH` فقط، بينما بعض الاستجابات تستخدم `isDash` أو تصف نوع البث عبر `container` أو `type` أو `mimeType` أو `format`.
- كانت بعض المصادر ترسل `height` أو `resolution` بدل `quality`، فيتحول الرابط إلى `unknown quality` ولا يُعرض ارتفاعه الحقيقي.
- موائم Unified-to-Legacy كان يسقط ارتفاع `UnifiedStreamOption.height` عندما لا يرسل المصدر تسمية جودة صريحة.
- بعض روابط HLS/DASH الرئيسية تأتي بعناوين دون امتداد `.m3u8` أو `.mpd`، وبوسم `Auto · Provider` بدل `Auto` حرفيًا؛ لذلك لم تكن تُكتشف دائمًا كروابط تكيفية.
- فاحص HLS السابق افترض أن URI الخاص بالـvariant يأتي مباشرة في السطر التالي لـ`#EXT-X-STREAM-INF`، بينما بعض المزوّدين يضعون أسطرًا فارغة أو تعليقات بينهما.

### ب. النتائج التكيفية كانت تُحفظ كرابط Auto واحد

- كتالوج الجودة مستقل عن BetterPlayer tracks، لذلك يحتاج إلى ارتفاعات الـmanifest لكل مزوّد؛ مسارات BetterPlayer الداخلية تخص الرابط النشط فقط.
- لم يكن استخراج ارتفاعات manifest يغطي بما يكفي الروابط ذات العناوين غير القياسية وبيانات النوع الناقصة.
- كانت هناك مسارات تحميل يدوي/كسول للمزوّدين تحتاج أن تطلق الفحص التكيفي بعد وصول روابطها أيضًا.

### ج. أولوية الترجمات العربية

- كانت إزالة التكرار تحدث قبل ترتيب المصادر في بعض الحالات، ما قد يبقي نسخة من مزوّد آخر ويزيل نتيجة SubSource ذات الإصدار نفسه أو الرابط نفسه.
- أصبح ترتيب أولوية اللغة والمزوّد يسبق إزالة التكرار، فتكون SubSource أول محاولة عربية، ثم OpenSubtitles، ثم SubDL وArabicSubs/Scraper حسب ما هو مفعّل ومتاح.
- فشل تنزيل نتيجة SubSource لا يمنع تجربة النتيجة التالية.

### د. عناصر تحكم الأفلام

- عند تفعيل `useTvControls` كان BetterPlayerTvControls يُستخدم للأفلام أيضًا، فيفصل Audio وSubtitles ويعرض زر جودة HD أصليًا، ويعطي تخطيط الأيقونات بدل شريط FlixQuest Material النصي.
- أصبح اختيار عناصر التحكم للأفلام منفصلًا: الأفلام تستخدم Material controls، بينما تبقى المسلسلات والأنمي على BetterPlayerTvControls الحالي دون تغيير.

## التغييرات المنفذة

### جودة الفيديو

- توسيع `AdaptiveQualityScanner` لاكتشاف HLS/DASH من العلامات، الامتدادات، `quality`، MIME type وبنية manifest.
- تمرير headers الخاصة بالرابط عند طلب manifest، مع عدم تمرير بيانات الاعتماد إلى مضيف CDN مختلف عند متابعة قوائم HLS الفرعية.
- دعم ملفات HLS التي تحتوي أسطرًا فارغة وتعليقات بين `EXT-X-STREAM-INF` وURI.
- قراءة `RESOLUTION` و`NAME` من HLS، و`height` من DASH Representation.
- استنتاج ارتفاع HLS من مقاطع URI الصريحة مثل `/1080p/index.m3u8` عندما يحذف المصدر `RESOLUTION` و`NAME`.
- متابعة عدد محدود من قوائم HLS الفرعية إذا كانت القائمة الرئيسية لا تكشف الدقات.
- توحيد قراءة `isDASH` و`isDash` و`isHLS` ومعلومات container/type/MIME/format في Scraper API.
- قراءة الجودة من `quality`، أو `height`، أو أبعاد `resolution`، وحفظ `availableHeights` من القوائم أو الخرائط.
- الاحتفاظ بارتفاع `UnifiedStreamOption.height` عند غياب تسمية جودة في الموائم.
- اعتبار تسميات `Auto` و`Adaptive` و`Master` التي يتبعها اسم المزوّد روابط تكيفية.
- استمرار تحديث كتالوج الجودة من نتائج المصادر والفحص الخلفي، دون استدعاء `setupDataSource` أو تغيير عنوان التشغيل الحالي. تغيير المصدر/الجودة يحدث فقط عند اختيار المستخدم.
- إطلاق فحص manifest أيضًا بعد التحميل اليدوي/الكسول للمزوّد.

### الترجمة العربية

- ترتيب نتائج اللغة المفضلة حسب أولوية المزوّد قبل إزالة تكرار URL أو الإصدار.
- في العربية: SubSource أولًا، ثم OpenSubtitles، ثم SubDL وArabicSubs/مصدر Scraper حسب التوفر.
- تستمر محاولة بقية النتائج عند غياب SubSource أو فشل تنزيل الملف.

### عناصر تحكم الأفلام

- الأفلام تستخدم FlixQuest Material controls حتى عندما يكون `useTvControls` مفعّلًا.
- يظهر شريط الأزرار النصية: Speed، Lock، Switch Provider، More Like This، Audio & Subtitles.
- إخفاء زر HD الأصلي المكرر للأفلام؛ كتالوج الجودة الموحد يبقى منفصلًا عن هذا الشريط.
- المسلسلات والأنمي تحتفظ بمسار TV controls كما كان.

## الملفات المعدّلة

- `lib/screens/common/player.dart`
- `lib/services/external_subtitle_service.dart`
- `lib/video_providers/adaptive_quality_scanner.dart`
- `lib/video_providers/quality_catalog.dart`
- `lib/video_providers/scraper_api.dart`
- `lib/video_providers/unified/legacy_provider_adapter.dart`
- `test/adaptive_quality_scanner_test.dart`
- `test/quality_catalog_test.dart`
- `test/scraper_api_test.dart`
- `test/video_providers/legacy_provider_adapter_test.dart`
- `test/external_subtitle_service_test.dart`
- `test/provider_background_scan_test.dart`

## اختبارات الانحدار المضافة/المحدّثة

- اكتشاف HLS extensionless مع أسطر فارغة وتعليقات، واتباع قائمة فرعية.
- استنتاج ارتفاع HLS من مقاطع URI الصريحة عند غياب RESOLUTION/NAME.
- اكتشاف DASH extensionless من MIME type.
- استخدام HLS `NAME` عندما لا توجد RESOLUTION.
- تمرير headers عند طلب manifest.
- توسيع روابط Auto التي تحمل suffix باسم المزوّد إلى عناصر adaptive.
- قراءة `isDash` وارتفاعات النص/الأرقام و`height` من استجابات Scraper API.
- الحفاظ على الارتفاع عند تحويل UnifiedStreamOption إلى النموذج القديم.
- الحفاظ على SubSource عند تعارض URL أو release مع مزوّد عربي آخر.
- الاحتفاظ بالارتفاعات غير القياسية والنتائج التي وصلت أثناء إكمال هدف 1080p/720p/480p.

## حالة التحقق

- تمت مراجعة الملفات والتغييرات المصدرية وإنشاء اختبارات الانحدار.
- لم يتم تشغيل `flutter test` أو `flutter build apk --release` في بيئة العمل الحالية لعدم توفر Flutter/Dart SDK.
- يلزم التحقق النهائي عبر GitHub Actions، ثم تجربة قائمة Quality على أكثر من مزوّد HLS/DASH، وتجربة ترجمة عربية من SubSource، والتحقق من تخطيط Controls للأفلام مع التأكد من بقاء المسلسلات والأنمي كما هما.

## سياسة المراحل

هذا التقرير مستقل داخل `phases/`. تبقى تقارير المراحل السابقة محفوظة، ويُستخدم الرقم 18 للمرحلة التالية.
