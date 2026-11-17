import { expect, request, test } from "@playwright/test";
import { createHash, randomUUID } from "node:crypto";

const API = "http://127.0.0.1:8011/api/v1";
// a real 1x1 PNG so the browser can actually render the "meter photo"
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");

test("manager runs a full week in the Arabic RTL console; phone syncs through the API", async ({ page }) => {
  const shots = test.info().outputPath();
  // --- login + RTL
  await page.goto("/");
  await expect(page).toHaveURL(/\/login/);
  await expect(page.locator("html")).toHaveAttribute("dir", "rtl");
  await page.getByLabel("اسم المستخدم").fill("e2e-manager");
  await page.getByLabel("كلمة المرور").fill("wrong-password");
  await page.getByRole("button", { name: "تسجيل الدخول" }).click();
  await expect(page.getByText("اسم المستخدم أو كلمة المرور غير صحيحة")).toBeVisible();
  await page.getByLabel("كلمة المرور").fill("E2e-Manager-Pass1");
  await page.getByRole("button", { name: "تسجيل الدخول" }).click();
  await expect(page.getByRole("heading", { name: "لوحة المتابعة" })).toBeVisible();
  // tokens are NOT readable by page JavaScript
  expect(await page.evaluate(() => document.cookie)).not.toContain("gms_");

  // --- generator + zone
  await page.getByRole("link", { name: "المولدات والمناطق" }).click();
  await page.getByRole("button", { name: "+ مولد" }).click();
  await page.locator(".modal").getByLabel("اسم المولد").fill("مولد الاختبار E2E");
  await page.getByRole("button", { name: "حفظ" }).click();
  await page.locator(".card", { hasText: "مولد الاختبار E2E" }).getByRole("button", { name: "+ منطقة" }).click();
  await page.locator(".modal").getByLabel("اسم المنطقة").fill("حي الاختبار");
  await page.getByRole("button", { name: "حفظ" }).click();
  await expect(page.getByRole("cell", { name: "حي الاختبار" })).toBeVisible();

  // --- employee, zone grant, phone enrollment code
  await page.getByRole("link", { name: "الموظفون والحسابات" }).click();
  await page.getByRole("button", { name: "+ حساب جديد" }).click();
  await page.locator(".modal").getByLabel("الاسم الكامل").fill("موظف الاختبار");
  await page.locator(".modal").getByLabel("اسم المستخدم").fill("e2e-field");
  await page.getByRole("button", { name: "إنشاء" }).click();
  const tempPw = (await page.locator(".modal .reading-big").innerText()).trim();
  await page.getByRole("button", { name: "تم" }).click();
  const row = page.getByRole("row", { name: /موظف الاختبار/ });
  await row.getByRole("button", { name: "+ منطقة" }).click();
  await page.locator(".modal select").selectOption({ label: "مولد الاختبار E2E — حي الاختبار" });
  await page.getByRole("button", { name: "منح" }).click();
  await expect(row.getByText("حي الاختبار")).toBeVisible();
  await row.getByRole("button", { name: "رمز تفعيل هاتف" }).click();
  const code = (await page.locator(".modal .reading-big").innerText()).trim();
  await page.getByRole("button", { name: "تم" }).click();

  // --- subscriber with meter + opening reading (3 decimals refused in the UI, never rounded)
  await page.getByRole("link", { name: "المشتركون والعدادات" }).click();
  await page.getByRole("button", { name: "+ مشترك جديد" }).click();
  await page.locator(".modal").getByLabel("رقم الاشتراك").fill("E2E-1001");
  await page.locator(".modal").getByLabel("الاسم الكامل").fill("مشترك تجريبي");
  await page.locator(".modal").getByLabel("المولد / المنطقة").selectOption({ label: "مولد الاختبار E2E — حي الاختبار" });
  await page.locator(".modal").getByLabel("رقم العداد").fill("E2E-M-1");
  await page.locator(".modal").getByLabel("القراءة الافتتاحية kWh").fill("100.123");
  await expect(page.getByText("مسموح بـ 2 منزلة عشرية كحد أقصى")).toBeVisible();
  await page.locator(".modal").getByLabel("القراءة الافتتاحية kWh").fill("100.00");
  await page.getByRole("button", { name: "حفظ" }).click();
  await expect(page.getByRole("link", { name: "E2E-1001" })).toBeVisible();

  // --- cycle (today's week), open, provisional rate, extra task
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Gaza" }).format(new Date());
  const plus = (n: number) => new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Gaza" }).format(new Date(Date.now() + n * 86400000));
  await page.getByRole("link", { name: "الدورات والأسعار" }).click();
  await page.getByRole("button", { name: "+ دورة جديدة" }).click();
  await page.locator(".modal").getByLabel("اسم الدورة").fill("أسبوع E2E");
  await page.locator(".modal").getByLabel("من").fill(plus(-3));
  await page.locator(".modal").getByLabel("إلى").fill(plus(3));
  await page.getByRole("button", { name: "حفظ" }).click();
  await page.getByRole("link", { name: "أسبوع E2E" }).click();
  await page.getByRole("button", { name: "فتح الدورة" }).click();
  await page.getByRole("button", { name: "سعر مبدئي" }).click();
  await page.locator(".modal").getByLabel("السعر ₪ لكل kWh").fill("14");
  await page.getByRole("button", { name: "حفظ" }).click();
  await expect(page.locator(".stat", { hasText: "السعر المبدئي" })).toContainText("14");
  await page.getByRole("link", { name: "المهام والتكليفات" }).click();
  await page.getByRole("button", { name: "+ مهمة استثنائية" }).click();
  await page.locator(".modal").getByLabel("ابحث عن المشترك").fill("E2E");
  await page.getByRole("button", { name: /مشترك تجريبي — E2E-1001/ }).click();
  await page.locator(".modal input[type=date]").fill(today);
  await page.getByRole("button", { name: "إنشاء" }).click();
  await expect(page.getByRole("row", { name: /مشترك تجريبي/ })).toContainText("مكلّفة");

  // --- the phone (API only; no DB access): enroll, change temp password, bootstrap, sync, photo
  const phone = await request.newContext();
  const install = randomUUID().replace(/-/g, "");
  let r = await phone.post(`${API}/auth/login`, { data: { username: "e2e-field", password: tempPw, client: "mobile", install_id: install, enrollment_code: code } });
  expect(r.ok()).toBeTruthy();
  let tok = (await r.json()).access_token;
  r = await phone.post(`${API}/auth/change-password`, { data: { current_password: tempPw, new_password: "Field-Pass-2026" }, headers: { authorization: `Bearer ${tok}` } });
  tok = (await r.json()).access_token;
  const auth = { authorization: `Bearer ${tok}` };
  const boot = await (await phone.get(`${API}/mobile/bootstrap`, { headers: auth })).json();
  expect(boot.tasks).toHaveLength(1);
  const sub = boot.subscribers[0];
  const visit = randomUUID();
  const op = { kind: "visit", operation_id: randomUUID(), visit_id: visit, payload: { subscriber_id: sub.id, installation_id: sub.installation_id, zone_id: sub.zone_id, task_id: boot.tasks[0].id, event_kind: "reading", reading_value_kwh: "101.43", captured_at_device: new Date(Date.now() - 1_000).toISOString() } };
  for (let i = 0; i < 3; i++) {
    const res = await (await phone.post(`${API}/mobile/sync`, { data: { device_now: new Date().toISOString(), operations: [op] }, headers: auth })).json();
    expect(res.results[0].result, JSON.stringify(res.results[0])).toBe(i === 0 ? "accepted" : "already_received");
    if (i === 0) expect(res.results[0].flags).toEqual([]);
  }
  const sha = createHash("sha256").update(PNG).digest("hex");
  r = await phone.put(`${API}/mobile/photos/${randomUUID()}?visit_id=${visit}&is_primary=true&sha256=${sha}`, { data: PNG, headers: { ...auth, "content-type": "application/octet-stream" } });
  expect((await r.json()).record_status).toBe("pending_review");

  // --- manager reviews the photo and approves
  await page.getByRole("link", { name: "مراجعة القراءات" }).click();
  await page.getByRole("link", { name: "مراجعة", exact: true }).first().click();
  await expect(page.locator(".reading-big").first()).toHaveText("101.43");
  const img = page.locator(".photo-grid img").first();
  await expect(img).toBeVisible();
  expect(await img.evaluate((el: HTMLImageElement) => el.complete && el.naturalWidth > 0)).toBeTruthy();
  await page.screenshot({ path: `${shots}/review.png`, fullPage: true });
  await page.getByRole("button", { name: "اعتماد / تصحيح" }).click();
  await page.getByRole("button", { name: "اعتماد", exact: true }).click();
  await expect(page.locator(".page-header .badge")).toHaveText("معتمدة");

  // --- close the week with the final rate: 1.43 kWh x 15 = 21.45 -> request 21, carry 0.45
  await page.getByRole("link", { name: "الدورات والأسعار" }).click();
  await page.getByRole("link", { name: "أسبوع E2E" }).click();
  await expect(page.getByText("لا توجد عوائق للإغلاق")).toBeVisible();
  await page.getByRole("button", { name: "تثبيت السعر النهائي وإغلاق" }).click();
  await page.locator(".modal").getByLabel("السعر النهائي الموحّد ₪/kWh").fill("15");
  await page.locator(".modal").getByLabel("راجعت القراءات وأؤكد الإغلاق النهائي").check();
  await page.getByRole("button", { name: "تثبيت وإغلاق" }).click();
  await expect(page.locator(".page-header .badge")).toHaveText("مغلقة");
  await page.getByRole("link", { name: "الكشوف الأسبوعية" }).click();
  const st = page.getByRole("row", { name: /مشترك تجريبي/ });
  await expect(st).toContainText("21.45 ₪");
  await expect(st).toContainText("21.00 ₪");
  await expect(st).toContainText("0.45 ₪");
  const dl = page.waitForEvent("download");
  await page.getByRole("button", { name: "طباعة الكشوف PDF" }).click();
  expect((await (await dl).path())).toBeTruthy();

  // --- partial payment by the manager, then reversal kept as a counter entry
  await page.getByRole("link", { name: "المدفوعات" }).click();
  await page.getByLabel("ابحث عن المشترك (الاسم أو رقم الاشتراك)").fill("E2E");
  await page.getByRole("button", { name: /مشترك تجريبي — E2E-1001/ }).click();
  await page.locator(".modal").getByLabel("المبلغ المقبوض فعليًا ₪").fill("10");
  await page.getByRole("button", { name: "تسجيل الدفعة" }).click();
  await expect(page.locator(".modal")).toContainText("11.00 ₪");
  await page.getByRole("button", { name: "إغلاق" }).last().click();
  await page.getByRole("row", { name: /مشترك تجريبي/ }).getByRole("button", { name: "إلغاء بقيد عكسي" }).click();
  await page.locator(".modal").getByLabel("السبب").fill("اختبار الإلغاء");
  await page.getByRole("button", { name: "تأكيد" }).click();
  await expect(page.getByRole("row", { name: /مشترك تجريبي/ })).toContainText("ملغاة");
  await page.getByRole("link", { name: "المشتركون والعدادات" }).click();
  await page.getByRole("link", { name: "E2E-1001" }).click();
  await page.getByRole("button", { name: "دفتر الحساب" }).click();
  await expect(page.locator("table tbody tr")).toHaveCount(3);
  await expect(page.locator(".stat", { hasText: "المطلوب (شيكل صحيح)" })).toContainText("21.00 ₪");
  await page.screenshot({ path: `${shots}/subscriber-ledger.png`, fullPage: true });

  // --- the employee token is refused by manager endpoints even through direct API calls
  r = await phone.post(`${API}/payments`, { data: { subscriber_id: sub.id, amount_ils: "5", paid_at: new Date().toISOString(), method: "cash", idempotency_key: randomUUID() }, headers: auth });
  expect(r.status()).toBe(403);
  // and the BFF refuses cross-site style mutations without the CSRF header
  const csrf = await page.request.post("/bff/generators", { data: { name: "x" } });
  expect(csrf.status()).toBe(403);
  // --- mobile layout stays usable (no horizontal page scroll)
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/subscribers");
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBeTruthy();
  await page.screenshot({ path: `${shots}/mobile-subscribers.png`, fullPage: true });
});
