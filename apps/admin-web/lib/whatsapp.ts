/**
 * WhatsApp Quick-Send Helpers for GMS Statements and Payment Receipts.
 */

export function sanitizePhone(rawPhone?: string | null): string {
  if (!rawPhone) return "";
  let digits = rawPhone.replace(/\D/g, "");
  // If local Palestine/Israel mobile 059... or 056...
  if (digits.startsWith("059") || digits.startsWith("056")) {
    digits = "970" + digits.slice(1);
  } else if (digits.startsWith("05")) {
    digits = "972" + digits.slice(1);
  }
  return digits;
}

export function openWhatsApp(phone: string | null | undefined, text: string, defaultName: string = "المشترك") {
  let clean = sanitizePhone(phone);
  if (!clean) {
    const promptNumber = window.prompt(
      `لم يتم تسجيل رقم هاتف لـ (${defaultName}).\nيرجى إدخال رقم الهاتف لإرسال الرسالة عبر واتساب (مثال: 0599123456):`
    );
    if (!promptNumber) return;
    clean = sanitizePhone(promptNumber);
  }

  const encoded = encodeURIComponent(text);
  const url = `https://wa.me/${clean}?text=${encoded}`;
  window.open(url, "_blank", "noopener,noreferrer");
}

export function buildStatementWhatsAppText(s: any, businessName: string = "نظام إدارة المولدات"): string {
  const subName = s.subscriber_name || "المشترك";
  const cycleLabel = s.cycle_label || "";
  const subNo = s.subscription_no || "";
  const kwh = s.consumption_kwh ?? "0";
  const rate = s.rate_snapshot_ils_per_kwh ?? "";
  const cost = s.charge_exact_ils ?? "0";
  const prevBalance = s.opening_ledger_balance_ils ?? "0";
  const requested = s.requested_whole_ils ?? "0";

  return `السلام عليكم ورحمة الله أخي/أختي *${subName}* ⚡
من: *${businessName}*

نرفق لكم تفاصيل فاتورة الكهرباء للدورة: *${cycleLabel}*
───────────────────────────
🔹 *رقم الاشتراك:* ${subNo}
🔹 *الاستهلاك:* ${kwh} ك.و.س
${rate ? `🔹 *سعر الكيلوواط:* ${rate} ₪` : ""}
🔹 *قيمة استهلاك الدورة:* ${cost} ₪
🔹 *الرصيد السابق:* ${prevBalance} ₪
───────────────────────────
💵 *المبلغ المطلوب سداده:* *${requested} شيكل*
───────────────────────────
نشكر لكم حسن تعاونكم والتزامكم بالسداد في الموعد المحدد. دمتم بخير!`;
}

export function buildPaymentReceiptWhatsAppText(p: any, businessName: string = "نظام إدارة المولدات"): string {
  const subName = p.subscriber_name || "المشترك";
  const subNo = p.subscription_no || "";
  const receiptNo = p.receipt_no || "";
  const amount = p.amount_ils ?? "0";
  const method = p.payment_method === "cash" ? "نقدًا" : p.payment_method === "bank_transfer" ? "تحويل بنكي" : "أخرى";
  const paidAt = p.paid_at ? new Date(p.paid_at).toLocaleDateString("ar-EG") : "";

  return `🧾 *سند قبض إلكتروني*
من: *${businessName}*

تم استلام دفعة مالية من المشترك: *${subName}*
───────────────────────────
🔹 *رقم الاشتراك:* ${subNo}
🔹 *رقم السند:* *${receiptNo}*
🔹 *المبلغ المقبوض:* *${amount} شيكل*
🔹 *طريقة الدفع:* ${method}
${paidAt ? `🔹 *التاريخ:* ${paidAt}` : ""}
───────────────────────────
شاكرين لكم حسن تعاونكم وثقتكم بنا.`;
}
