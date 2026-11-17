# P0 — تدقيق المرجع والبيئة (نتائج منفذة فعليًا)

التاريخ: 2026-11-14 — كل ما في هذا الملف ناتج أوامر شُغّلت على هذه الآلة.

## 1. البيئة

| الأداة | الحالة |
|---|---|
| Windows 11 Pro، Docker 29.9.3 (يعمل) | متاح |
| PostgreSQL للاختبار | حاوية معزولة `gms-pg-test` (postgres:16-alpine = 16.16) على `127.0.0.1:55432` ببيانات tmpfs. خدمة PostgreSQL 18 المحلية وحاويات المشاريع الأخرى (5432/5433/8000) **لم تُلمس** |
| Python 3.14 (venv في `services/api/.venv`)، Node 26.13، Java 17، Git | متاح |
| Android SDK (`%LOCALAPPDATA%\Android\Sdk`) | متاح |
| Flutter / Dart | **غير مثبت** — يؤثر على P6 فقط |
| المستودع | ليس مستودع Git (لم يُنشأ commit) |

## 2. تشغيل المرجع 2.2 كما هو (دون أي تعديل)

```text
python -m unittest discover -s tests -p 'test_*.py'      -> Ran 12 tests, OK (مرجع Decimal وفحوص ساكنة فقط)
psql -f 10_baseline.sql / 20_hardening.sql / 30_financial_engine.sql  -> exit 0 (تُنشأ الكائنات)
psql -f tests/pg_integration.sql -> FAIL
  ERROR:  record "p" is not assigned yet
  CONTEXT: ... gms_check_approved_insert() line 16 ... gms_approve_visit(uuid,numeric) line 54
```

أي أن **اعتماد أي قراءة كان مستحيلًا** في SQL 2.2: متغير PL/pgSQL باسم `p` يحجب alias الجدول `visit_photos p`.

بعد إصلاحين دنيا على نسخة مؤقتة (alias → `ph`، وإضافة `#variable_conflict use_column` لسكربت الاختبار نفسه لأنه يفشل بـ `column reference "subscriber_id" is ambiguous`) طُبع `GMS QA PASS`. لكن فحوصًا إضافية على النسخة «الناجحة» أثبتت:

| # | عيب مثبت بالتشغيل | الأثر |
|---|---|---|
| D1 | `gms_check_approved_insert`: حجب alias | لا اعتماد إطلاقًا |
| D2 | سكربت الاختبار المرجعي غامض المراجع، واختبار «الدقة» فيه ينجح بسبب trigger آخر لا بسبب فحص الدقة | الاختبار لا يثبت ما يدّعيه |
| D3 | دورة أُغلقت وفيها زيارة غير مجدولة (`task_id NULL`) معلقة: `finalize` أعاد 0 والحالة `closed` | مخالفة BR-05/FR-28 |
| D4 | الزيارة تبقى `awaiting_photo` بعد تسجيل صورة ready | لا انتقال حالة للمراجعة |
| D5 | سياق «موظف» أنشأ مولدًا وحساب **مدير** بـ INSERT مباشر | لا حماية للبيانات الرئيسية ولا أدوار DB |
| D6 | `gms_guard_approved` يقارن العمود المولَّد `consumption_kwh` قبل حسابه | أي استبدال/تصحيح لقراءة معتمدة يُرفض دائمًا |
| D7 | `text[] || 'literal'` وأنماط مشابهة، payload ناقص يرفع استثناء خام بدل نتيجة `rejected` | مزامنة هشة |
| D8 | FK `(subscriber_id, zone_id)` على الزيارات/المهام يمنع تغيير منطقة مشترك له تاريخ | قيد تشغيلي خاطئ |
| D9 | لا مسار للقراءة المتأخرة بعد الإغلاق، ولا لتصحيح قراءة لها لاحقات، ولا لإعادة الزيارة | BR-21/25 غير منفذة |
| D10 | الإغلاق ممكن بـ UPDATE مباشر دون كشوف؛ السعر النهائي يُثبَّت خارج الإغلاق | تجاوز المحرك المالي |

## 3. تعارضات وثائقية

- `QA_Report.md` يذكر المراجع 2.1 في رأسه بينما الحزمة 2.2؛ لا أثر تنفيذي.
- SRS §16 (FIX-07) يفرض «أسبوع مفتوح واحد»؛ أبقيناه، ونتيجته التشغيلية موثقة في القرار D-03.
- الخطة تذكر «presigned upload»؛ نُفذ الرفع عبر الـ API للتحقق من المحتوى قبل `ready` (قرار D-05).

## 4. القرار

لا يُعتمد SQL 2.2 كـ migration. بُني baseline جديد في `db/sql/0000..0006` (schema صريح `gms`) يُطبَّق عبر Alembic، مع حزمة اختبارات PostgreSQL حقيقية (`services/api/tests/db`). النتائج في `docs/progress.md` و`docs/evidence/`.
