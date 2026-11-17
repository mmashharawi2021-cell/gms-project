import { expect, test } from "@playwright/test";
import path from "node:path";

// Synthetic fixture: the client's own header names; one row has 3 decimals and must be refused, not rounded.
const FIXTURE = path.join(__dirname, "fixtures", "client-style.xlsx");

test("identity settings, Excel column mapping and receipt PDF", async ({ page }) => {
  await page.goto("/login");
  await page.getByLabel("اسم المستخدم").fill("e2e-manager");
  await page.getByLabel("كلمة المرور").fill("E2e-Manager-Pass1");
  await page.getByRole("button", { name: "تسجيل الدخول" }).click();
  await expect(page.getByRole("heading", { name: "لوحة المتابعة" })).toBeVisible();

  // business identity
  await page.getByRole("link", { name: "الإعدادات" }).click();
  const nameCard = page.locator(".card", { hasText: "اسم الجهة" });
  await nameCard.locator("input").fill("مولدات الاختبار");
  await nameCard.getByRole("button", { name: "حفظ" }).click();
  await expect(page.getByText("تم الحفظ").first()).toBeVisible();

  // generator + zone used by the file
  await page.getByRole("link", { name: "المولدات والمناطق" }).click();
  await page.getByRole("button", { name: "+ مولد" }).click();
  await page.locator(".modal").getByLabel("اسم المولد").fill("مولد الاستيراد");
  await page.locator(".modal").getByRole("button", { name: "حفظ" }).click();
  await page.locator(".card", { hasText: "مولد الاستيراد" }).getByRole("button", { name: "+ منطقة" }).click();
  await page.locator(".modal").getByLabel("اسم المنطقة").fill("حي الاستيراد");
  await page.locator(".modal").getByRole("button", { name: "حفظ" }).click();

  // import with on-screen mapping
  await page.getByRole("link", { name: "استيراد Excel" }).click();
  await page.locator('input[type="file"]').setInputFiles(FIXTURE);
  const row = (title: string) => page.getByRole("row", { name: new RegExp(title) });
  await expect(row("رقم الاشتراك").locator("select")).toHaveValue("الرقم");          // suggested automatically
  await expect(row("القراءة الافتتاحية").locator("select")).toHaveValue("آخر قراءة");
  await row("^المولد").locator("select").selectOption("__const");
  await row("^المولد").locator("td").nth(2).locator("input").fill("مولد الاستيراد");
  await row("نوع العداد").locator("select").selectOption("__const");
  await row("نوع العداد").locator("td").nth(2).locator("input").fill("رقمي");
  await page.getByRole("button", { name: "معاينة وفحص" }).click();
  await expect(page.getByRole("row", { name: /E2E-X1/ })).toContainText("جديد");
  await expect(page.getByRole("row", { name: /E2E-X2/ })).toContainText("121.987");
  await expect(page.getByRole("row", { name: /E2E-X2/ })).toContainText("خطأ");
  await page.getByRole("button", { name: "تأكيد استيراد 1 مشترك" }).click();
  await expect(page.getByText("أُنشئ 1 مشترك")).toBeVisible();

  // payment + receipt PDF
  await page.getByRole("link", { name: "المدفوعات" }).click();
  await page.getByLabel("ابحث عن المشترك (الاسم أو رقم الاشتراك)").fill("E2E-X1");
  await page.getByRole("button", { name: /مستورد أول/ }).click();
  await page.locator(".modal").getByLabel("المبلغ المقبوض فعليًا ₪").fill("12.50");
  await page.getByRole("button", { name: "تسجيل الدفعة" }).click();
  const dl = page.waitForEvent("download");
  await page.getByRole("button", { name: "إيصال PDF للطباعة" }).click();
  const file = await (await dl).path();
  expect(file).toBeTruthy();
  const fs = await import("node:fs");
  expect(fs.readFileSync(file!).subarray(0, 4).toString()).toBe("%PDF");
});
