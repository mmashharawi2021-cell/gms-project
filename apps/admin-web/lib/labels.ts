export const VISIT_STATUS: Record<string, [string, string]> = {
  awaiting_photo: ["بانتظار الصورة", "warn"],
  pending_review: ["بانتظار المراجعة", "info"],
  exception: ["استثناء يحتاج قرار", "danger"],
  approved: ["معتمدة", "ok"],
  rejected: ["مرفوضة", "muted"],
  needs_revisit: ["إعادة زيارة", "warn"],
  unreadable_resolved: ["تعذر — مغلق", "muted"],
  incident_resolved: ["بلاغ — محسوم", "muted"],
};
export const TASK_STATUS: Record<string, [string, string]> = {
  assigned: ["مكلّفة", "info"],
  in_progress: ["قيد التنفيذ", "info"],
  pending_review: ["بانتظار المراجعة", "warn"],
  completed_reading: ["مقروءة", "ok"],
  completed_unreadable: ["متعذرة — مغلقة", "muted"],
  revisit_required: ["إعادة زيارة", "warn"],
  cancelled: ["ملغاة", "muted"],
};
export const TASK_SOURCE: Record<string, string> = {
  scheduled: "مجدولة", manager_extra: "استثنائية", revisit: "إعادة زيارة", unreadable_followup: "متابعة تعذر", closing: "قراءة ختامية",
};
export const CYCLE_STATE: Record<string, [string, string]> = {
  draft: ["مسودة", "muted"], open: ["مفتوحة", "ok"], closed: ["مغلقة", "info"],
};
export const EVENT_KIND: Record<string, string> = { reading: "قراءة", unreadable: "تعذر قراءة", meter_incident: "بلاغ عداد" };
export const FLAGS: Record<string, string> = {
  unscheduled: "زيارة إضافية خارج التكليف",
  no_zone_grant: "خارج صلاحية المنطقة وقت الالتقاط",
  zone_changed: "تغيرت منطقة المشترك",
  installation_inactive: "العداد غير مركب وقت الالتقاط",
  task_missing: "المهمة غير موجودة",
  task_mismatch: "التكليف تغيّر (Offline)",
  clock_future: "وقت الهاتف في المستقبل",
  clock_suspicious: "وقت الهاتف مشكوك فيه",
  late_sync: "مزامنة متأخرة",
  cycle_closed: "تتبع دورة مغلقة",
};
export const TIME_STATUS: Record<string, [string, string]> = {
  pending: ["غير موثّق", "warn"], consistent: ["متسق", "ok"], suspicious: ["مشكوك فيه", "danger"], corrected: ["مصحح بقرار المدير", "info"],
};
export const DECISION: Record<string, string> = {
  approve_reading: "اعتماد", correct_reading: "تصحيح القيمة", duplicate: "مكررة", reject: "رفض", request_revisit: "طلب إعادة زيارة",
  approve_unreadable: "إغلاق تعذر", correct_timestamp: "توثيق الوقت", accept_late: "قبول متأخرة", rechain: "إعادة ربط السلسلة", resolve_incident: "حسم بلاغ",
};
export const METHOD: Record<string, string> = { cash: "نقدًا", bank_transfer: "تحويل بنكي", other: "أخرى" };
export const LEDGER_SOURCE: Record<string, string> = {
  final_statement: "كشف نهائي", payment: "دفعة", payment_reversal: "إلغاء دفعة", adjustment: "تسوية", opening_receivable: "رصيد افتتاحي",
};
export const ERROR_HINT: Record<string, string> = {};
