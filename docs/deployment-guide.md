# دليل التثبيت والتشغيل والنشر — GMS

> هذا الدليل لبيئة تطوير/تجربة وبيئة إنتاج مستقبلية. **لا يُنشر النظام لعامة الإنترنت ولا تُستخدم بيانات حقيقية قبل موافقة صاحب المشروع** وتجاوز بوابات القبول (`docs/requirements-traceability.md`).

## 1. المكونات

| المكون | التقنية | المسار |
|---|---|---|
| قاعدة البيانات | PostgreSQL 16، schema `gms`، ترحيلات Alembic تنفذ ملفات `db/sql/0000..0006` | `db/sql`, `services/api/migrations` |
| الخادم API | FastAPI / Python 3.12، psycopg 3 | `services/api` |
| لوحة المدير | Next.js 16 (RTL عربي)، BFF بجلسات httpOnly | `apps/admin-web` |
| تطبيق الموظف | Flutter (Android) | `apps/field-mobile` |
| تخزين الصور | MinIO/S3 (إنتاج) أو نظام ملفات (تطوير) | — |
| النسخ الاحتياطي | `python -m app.ops.backup` + خدمة `backup` اليومية | `services/api/app/ops` |

## 2. نموذج الأمان في قاعدة البيانات (مهم قبل أي نشر)

- `gms_owner` (NOLOGIN) يملك جميع الكائنات. لا يتصل به أحد.
- `gms_api` دور مجموعة: قراءة الجداول، كتابة البيانات الرئيسية فقط (المولدات/المناطق/المشتركين/الحسابات…)، و`EXECUTE` على دوال الأعمال. **لا يملك INSERT/UPDATE/DELETE على القراءات أو المراجعات أو الدورات أو الأسعار أو الكشوف أو الدفعات أو الدفتر أو الأجهزة أو المهام أو الصور أو التدقيق** — كل ذلك يمر عبر دوال `SECURITY DEFINER` تتحقق من الدور داخل قاعدة البيانات.
- حساب دخول الـ API (مثل `gms_app`) عضو في `gms_api` فقط، يُنشأ بواسطة `python -m app.ops.dbsetup`.
- حساب الترحيل/النسخ (`GMS_DB_ADMIN_USER`) يُستخدم فقط من حاويتي `migrate` و`backup`. المشرف الفائق يستطيع تعطيل الحمايات؛ احصر الوصول إليه.
- الهاتف لا يتصل بقاعدة البيانات إطلاقًا.

## 3. التشغيل المحلي بـ Docker Compose

المتطلبات: Docker 24+ مع Compose v2.

```powershell
cd infra
copy .env.example .env      # ثم استبدل كل قيمة CHANGE_ME بأسرار عشوائية طويلة
docker compose up -d --build
docker compose logs -f migrate   # يجب أن ينتهي بـ: database ready; API login 'gms_app' has gms_api privileges only
```

إنشاء حساب المدير الأول (مرة واحدة؛ كلمة المرور تُطلب تفاعليًا ولا تُحفظ في أي ملف):

```powershell
docker compose run --rm api python -m app.cli create-first-manager --username admin --full-name "اسم المدير"
```

ثم افتح `http://localhost:3000`. واجهة OpenAPI: `http://localhost:8000/docs`.

الحاويات تنشر المنافذ على `127.0.0.1` فقط.

## 4. التشغيل للتطوير دون Docker للخدمات

```powershell
# قاعدة اختبار معزولة (بيانات في الذاكرة tmpfs)
docker run -d --name gms-pg-test -e POSTGRES_PASSWORD=gms_test_only -p 127.0.0.1:55432:5432 --tmpfs /var/lib/postgresql/data postgres:16-alpine

cd services/api
py -3 -m venv .venv ; .venv\Scripts\python -m pip install -e ".[dev]"
.venv\Scripts\python -m pytest            # 52 اختبارًا: قاعدة البيانات + API + نسخ واستعادة

cd ..\..\apps\admin-web
npm ci ; npx next build
npx playwright install chromium ; npx playwright test   # E2E متصفح حقيقي على قاعدة جديدة
```

متغيرات API (بادئة `GMS_`): `DATABASE_URL`, `JWT_SECRET` (32+ حرفًا), `STORAGE_BACKEND` (`filesystem`|`s3`), `STORAGE_DIR`, `S3_*`, `BACKUP_DIR`, `CORS_ORIGINS`. لا توضع الأسرار في المستودع؛ في الإنتاج استخدم مدير أسرار.

### اختبار الأداء

```powershell
cd services/api ; .venvScriptspython -m tests.perf.run_perf 5000 20   # ~10 دقائق؛ قاعدة مؤقتة تُحذف تلقائيًا
```

### CI

`.github/workflows/ci.yml` يشغّل كل الاختبارات على PostgreSQL 16 مؤقت عند أي push (بعد رفع المشروع إلى مستودع).

### تطبيق Android

```powershell
cd apps/field-mobile
C:Usersmozarlutterinlutter test
C:Usersmozarlutterinlutter build apk --release --dart-define=GMS_API_URL=https://your-domain
```
للتوزيع: أنشئ مفتاح توقيع واحفظ `android/key.properties` (storeFile, storePassword, keyAlias, keyPassword) خارج أي مستودع عام.

## 5. النشر للإنتاج (بعد الموافقة فقط)

1. خادم Linux مع Docker، ونطاق وشهادة TLS. ضع reverse proxy (Caddy/Nginx) أمام `web:3000` فقط؛ الـ API يُستدعى من الـ BFF داخليًا، ومن تطبيق Android عبر مسار `/api/` في الـ proxy نفسه (HTTPS إلزامي).
2. اضبط `X-Forwarded-Proto` في الـ proxy (ملفات تعريف الارتباط تصبح `Secure` تلقائيًا).
3. أسرار قوية في مدير أسرار؛ تدوير `GMS_JWT_SECRET` ينهي كل الجلسات.
4. خزّن الصور في S3/MinIO خاص (بلا وصول عام). روابط الصور تُصدر موقّعة ولمدة 10 دقائق.
5. انسخ مجلد النسخ الاحتياطية إلى موقع خارج الخادم (مثلًا تخزين كائنات منفصل) يوميًا.
6. نفّذ اختبار استعادة شهري (القسم 6).

## 6. النسخ الاحتياطي والاستعادة (BR-31، AT-15، AT-31)

- خدمة `backup` تنفّذ يوميًا الساعة 02:00 (المنطقة الزمنية للأعمال): `pg_dump` + أرشيف الصور + `manifest.json` ببصمات SHA-256، وتحتفظ بـ 30 يومًا. عميل PostgreSQL في الصورة إصدار 16 مطابق للخادم.
- يدويًا: `docker compose run --rm backup python -m app.ops.backup run manual`
- تنزيل يدوي للمدير من صفحة «النسخ الاحتياطية» بعد إعادة إدخال كلمة المرور (مُسجل في التدقيق).
- **الاستعادة تكون دائمًا إلى قاعدة جديدة** (ترفض الكتابة فوق قاعدة موجودة) ثم التحقق:

```bash
GMS_RESTORE_ADMIN_URL=postgresql://admin:...@host:5432/postgres \
python -m app.ops.backup restore /var/lib/gms/backups/gms-YYYYmmddTHHMMSSZ gms_restore_test /tmp/restored-photos
```

الأداة تتحقق من بصمات الملفات قبل البدء، وتطبع أعداد السجلات ومجموع الدفتر وفحص كل صورة مقابل بصمتها في القاعدة. للتحويل إلى الإنتاج بعد التحقق: أوقف الخدمات، وجّه `GMS_DATABASE_URL` إلى القاعدة المستعادة وارفع الصور إلى التخزين — بقرار وتوثيق صاحب المشروع.

## 7. الترحيلات وسياسة التراجع

- كل تغيير قادم = revision جديدة في `services/api/migrations/versions` (أمام فقط).
- `downgrade` للـ baseline يرفض التنفيذ إن وُجدت بيانات أعمال؛ التراجع في الإنتاج = استعادة نسخة ما قبل الترحيل (خذ نسخة يدوية قبل أي ترقية).

## 8. المراقبة

- `GET /health` (يتحقق من قاعدة البيانات)، healthcheck في الحاوية.
- صفحة «الأجهزة والمزامنة»: العمليات المرفوضة/المتعارضة، محاولات الأجهزة الموقوفة، الصور غير المكتملة.
- السجلات لا تتضمن قيم المعاملات أو كلمات المرور أو الرموز.
