# GMS — سجل تقدم Claude Code

| المرحلة | الحالة | نتائج الاختبارات | ملاحظات |
|---|---|---|---|
| P0 التدقيق | DONE | المرجع كما هو: **FAIL** على PostgreSQL 16.16 (`record "p" is not assigned yet`) | `docs/phase-00-audit.md` — 10 عيوب مثبتة بالتشغيل |
| P1 PostgreSQL | DONE | 17 اختبار سلامة/أدوار/workflow PASS | baseline جديد `db/sql/0000..0006` عبر Alembic |
| P2 المحرك المالي | DONE | 12 مالية + 9 تزامن PASS (مرجع Decimal مستقل) | `services/api/tests/db` |
| P3 API/Identity | DONE | 6 أمان/مصادقة + استيراد Excel PASS | FastAPI، JWT قصير + refresh دوّار مع كشف إعادة الاستخدام، RBAC على الخادم والقاعدة |
| P4 Scheduling | DONE | DB + HTTP PASS | توليد مهام، تكليف، ترحيل، إلغاء موثق، إغلاق بالتحقق |
| P5 Sync/Photos | DONE (خادم) | HTTP: idempotency، تعارض، صور SHA-256، نطاق المناطق PASS | تخزين ملفات/MinIO؛ عميل الهاتف في P6 |
| P6 Android | DONE | `flutter test` 10 PASS؛ APK debug بُني؛ سيناريو كامل على محاكي Android PASS | Flutter 3.50 مثبت في `C:\Users\mozar\flutter` |
| P7 Admin Web | DONE | build PASS؛ E2E Playwright متصفح حقيقي PASS | Next.js 16، RTL، BFF بجلسات httpOnly + CSRF |
| P8 Pricing/Reports | DONE | 2 اختبار تقارير PASS (PDF/Excel يطابقان البيانات، فحص بصري RTL) | 8 تقارير + طباعة الكشوف |
| P9 Payments | DONE | DB + HTTP + E2E PASS | دفع جزئي، عكس، تسويات، أرصدة افتتاحية |
| P10 Deploy/UAT | DONE (محليًا) | نسخ/استعادة PASS؛ Compose build + تشغيل كامل PASS | لا نشر عام (يتطلب موافقة)؛ UAT مع العميل لم يتم |

---

## P0 — تدقيق المرجع والبيئة

- **الأوامر:**
  - `py -m unittest discover -s tests -p 'test_*.py'` (في `reference/gms-2.2`) → `Ran 12 tests OK`.
  - `docker run -d --name gms-pg-test -p 127.0.0.1:55432:5432 --tmpfs /var/lib/postgresql/data postgres:16-alpine` → PostgreSQL 16.16.
  - تشغيل `10/20/30` ثم `tests/pg_integration.sql` كما هي على قاعدة فارغة `gms_ref_asis` → الملفات الثلاثة exit 0، الاختبار **FAIL exit 3**.
- **النتيجة:** المرجع غير صالح كـ migration. التفاصيل والعيوب D1–D10 في `docs/phase-00-audit.md`.
- **الملفات:** `docs/phase-00-audit.md`, `docs/assumptions-and-decisions.md`.

## P1 + P2 — قاعدة البيانات والمحرك المالي

- **الملفات المنشأة:**
  - `db/sql/0000_roles.sql` (أدوار `gms_owner` NOLOGIN و`gms_api`)، `0001_schema.sql` (38 جدولًا في schema `gms`)، `0002_guards.sql` (حماية/تدقيق)، `0003_finance.sql`، `0004_operations.sql`، `0005_field_review.sql`، `0006_grants.sql`.
  - `services/api/pyproject.toml`, `alembic.ini`, `migrations/` (revision `0001`؛ downgrade يرفض إن وُجدت بيانات أعمال — سياسة rollback = الاستعادة من نسخة ما قبل الترحيل).
  - `services/api/tests/{conftest,world,oracle}.py`، `tests/db/test_{integrity,finance,workflow,concurrency}.py`.
- **التصميم الأمني المثبت بالاختبار:** حساب الـ API (عضو `gms_api`) لا يملك INSERT/UPDATE/DELETE على القراءات والمراجعات والدورات والأسعار والكشوف والمدفوعات والدفتر والأجهزة والمهام والصور والتدقيق (18 محاولة → `42501`)؛ كل تغيير يمر عبر دوال `SECURITY DEFINER` تتحقق من الدور. حتى مالك الجداول يُمنع بالـ triggers من تعديل التاريخ (16 محاولة).
- **الأوامر:**
  - `GMS_MIGRATION_DATABASE_URL=... alembic upgrade head` على قاعدة فارغة → 38 جدولًا، 72 دالة، `alembic_version=0001`.
  - `services/api/.venv/Scripts/python -m pytest tests/db -v` → **38 passed** (الدليل: `docs/evidence/p1-p2-db-tests.txt`). اختبارات التزامن كُررت 3 مرات: 9/9 في كل مرة.
- **أخطاء اكتُشفت وأُصلحت أثناء المرحلة:** مقارنة العمود المولد في trigger القراءة المعتمدة (كانت تمنع أي تصحيح)؛ إعادة إرسال عملية سبق أن نتج عنها `conflict` كانت تعود `already_received` تحت السباق — أصبحت تعيد الحكم المخزن نفسه.
- **الفروقات عن SRS/المرجع:** موثقة في `docs/assumptions-and-decisions.md` (D-01..D-12).
- **الثغرات الباقية:** المشرف الفائق لقاعدة البيانات يستطيع تعطيل triggers (حد معروف في SRS §18.2)؛ الصور تتحقق في الـ API (P5).
- **القرار التالي:** P3 — FastAPI بالمصادقة وRBAC والـ CRUD واختبارات API سلبية.

## P3 → P9 — API، الويب، التقارير، المدفوعات، النسخ

- **الملفات:** `services/api/app/**` (config, db, deps, security, errors, storage, reports, routers/{auth,admin,subscribers,cycles,review,finance,mobile,imports,reports,system}, ops/{backup,dbsetup,scheduler}, cli)، `services/api/tests/{api,ops}`، `apps/admin-web/**` (24 مسارًا)، `apps/admin-web/e2e/flow.spec.ts`، `services/api/scripts/e2e_server.py`، `infra/docker-compose.yml`، `infra/.env.example`، Dockerfiles.
- **الأوامر والنتائج:**
  - `services/api/.venv/Scripts/python -m pytest` → **52 passed** (38 DB، 12 API، 2 نسخ/استعادة).
  - `npx tsc --noEmit` → بلا أخطاء؛ `npx next build` → نجح (24 مسارًا).
  - `npx playwright test` → **1 passed**: دخول، RTL، عدم وصول JavaScript للرموز، مولد/منطقة/موظف/صلاحية/رمز تفعيل، مشترك مع رفض 100.123، دورة وسعر مبدئي ومهمة، مزامنة الهاتف 3 مرات (accepted ثم already_received)، رفع صورة PNG حقيقية وعرضها، اعتماد، إغلاق بسعر 15 ← كشف 21.45/21/0.45 وتنزيل PDF، دفعة جزئية ثم عكسها، دفتر من 3 قيود، 403 للموظف على الدفعات، 403 CSRF، عرض الجوال 390px دون تمرير أفقي.
- **أخطاء اكتشفتها الاختبارات وأُصلحت:** التواريخ داخل الجمل العربية في PDF كانت تنقلب (`15-11-2026`) → صيغة `2026/11/15`؛ رمز ₪ غير موجود في خط Amiri فكان يختفي → «شيكل»؛ نافذة المشترك الجديد كانت تضع وقت تركيب العداد 12:00 فتُعلَّم قراءات الصباح «عداد غير مركب» → الوقت الحالي؛ أرقام الاشتراك اللاتينية كانت تتشوه داخل النص العربي → عزل bidi؛ `os.execv` على Windows كان يترك خادم E2E يتيمًا → تشغيل في المقدمة.
- **بيانات الاختبار:** اصطناعية موسومة (QA-*/E2E-*) في قواعد مؤقتة داخل حاوية الاختبار فقط.

## P6 + P10 — تطبيق Android والتشغيل

- **الملفات:** `apps/field-mobile/lib/**` (validators, models, store, secure, clock, photo_vault, api, sync, app_state, ui/*)، `android/app/src/main/kotlin/.../MainActivity.kt` (قناة الساعة الرتيبة)، manifest (لا نسخ احتياطي، HTTPS في الإصدار)، `test/{validators,sync}_test.dart`؛ `infra/docker-compose.yml` (SeaweedFS بدل MinIO)؛ `docs/{deployment-guide,user-guide-manager-ar,user-guide-employee-ar,acceptance-report}.md`.
- **الأوامر:** `git clone --depth 1 -b stable flutter` → Flutter 3.50.0/Dart 3.14؛ `flutter analyze` → 0 أخطاء؛ `flutter test` → 10 passed؛ `flutter build apk --debug` → نجح؛ تثبيت وتشغيل على محاكي (التفاصيل في `docs/acceptance-report.md` §3)؛ `docker compose build` → صورتان؛ `docker compose up` بأسرار مؤقتة → migrate/API/Web/backup تعمل ونسخة يدوية نجحت، ثم `down -v` للمشروع المؤقت فقط.
- **أخطاء أُصلحت:** Gradle Kotlin DSL (`java.util`)، اتصال قاعدة البيانات المشترك مع مهمة الخلفية، عدم تحديث المهام، العنوان الافتراضي المخفي، `resetOnError` في التخزين الآمن كان سيمسح مفتاح القاعدة.
- **متبقٍ:** مفتاح توقيع الإصدار، اختبار على هاتف حقيقي بالبصمة، اختبار أداء 5,000 مشترك.

## بعد P10 — الأداء ونسخة الإصدار وCI

- **اختبار الأداء** `tests/perf/run_perf.py` (5,000 مشترك، 20 موظفًا، 20 منطقة، 5,000 زيارة بصورها): البحث p95 0.17 ث؛ الإغلاق 12.9 ث؛ الدفتر مطابق للحساب المستقل (41,506,250.00). الدليل: `docs/evidence/perf-5000.json`.
- **تحسين:** طباعة الكشوف — تحميل السطور باستعلام واحد بدل استعلام لكل كشف، نص تذييل بأسطر ثابتة، وفلتر الطباعة حسب المنطقة في الـ API والويب.
- **جودة الكود:** `ruff` على كود الإنتاج → 0 ملاحظات بعد الإصلاح.
- **Android release:** `flutter build apk --release` نجح (66 MB)؛ تشغيل على محاكي مؤقت دون أعطال، وفرض HTTPS.
- **CI:** `.github/workflows/ci.yml` (Backend + lint، Web build + E2E، Mobile analyze/test/APK) — مكتوب، **لم يُشغّل** (لا مستودع بعيد).

## إضافات بلا حاجة لبيانات العميل

- **استيراد Excel لأي ملف:** `POST /imports/subscribers/inspect` يقرأ العناوين ويقترح الربط (مرادفات عربية/إنجليزية)، والرفع يقبل `mapping` (عمود أو قيمة ثابتة لكل حقل)، وتواريخ dd/mm/yyyy. شاشة ربط في الويب.
- **هوية الجهة:** ترحيل جديد `0002` (`db/sql/0007_identity_settings.sql`) لإعدادات الاسم/الهاتف/التذييل؛ تظهر في الكشوف والتقارير والإيصالات.
- **إيصال دفع PDF** `GET /payments/{id}/receipt` (الملغى موسوم)، وزر في الويب، ومُسجَّل في التدقيق.
- **ثغرة أُغلقت:** نص يبدأ بـ `=` (مثل اسم مشترك مستورد) كان سيُكتب صيغة فعالة في تقارير Excel (Formula Injection) — صار نصًا دائمًا، ومغطى باختبار.
- **طباعة متوازية للكشوف** ودمج بالترتيب (pypdf): 2,000 صفحة 56 ث ← 24 ث.
- **الأوامر:** `pytest` → 55 passed؛ `ruff` نظيف؛ `npx playwright test` → 2 passed؛ `docker compose build` → نجح.
