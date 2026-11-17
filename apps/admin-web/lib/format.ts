// Exact display of decimal STRINGS returned by the API. No parseFloat anywhere for money/kWh.
export function groupDigits(intPart: string) {
  return intPart.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

export function num(v: string | number | null | undefined, minDecimals = 0): string {
  if (v === null || v === undefined || v === "") return "—";
  let s = String(v);
  const neg = s.startsWith("-");
  if (neg) s = s.slice(1);
  let [i, f = ""] = s.split(".");
  while (f.length < minDecimals) f += "0";
  return (neg ? "-" : "") + groupDigits(i) + (f ? "." + f : "");
}

export const money = (v: any) => (v === null || v === undefined ? "—" : `${num(v, 2)} ₪`);
export const kwh = (v: any) => (v === null || v === undefined ? "—" : num(v));

export const KWH_RE = /^\d{1,14}(\.\d{1,2})?$/;
export const MONEY_RE = /^-?\d{1,9}(\.\d{1,2})?$/;
export const RATE_RE = /^\d{1,10}(\.\d{1,6})?$/;

export function checkDecimal(v: string, re: RegExp, places: number): string | null {
  const s = v.trim();
  if (!s) return "القيمة مطلوبة";
  if (/^-?\d+\.\d+$/.test(s) && s.split(".")[1].length > places)
    return `مسموح بـ ${places} منزلة عشرية كحد أقصى — لن يتم التقريب تلقائيًا`;
  if (!re.test(s)) return "قيمة رقمية غير صالحة";
  return null;
}

let TZ = "Asia/Gaza";
export function setTimezone(tz: string) {
  TZ = tz || TZ;
}
export function dt(v: string | null | undefined) {
  if (!v) return "—";
  return new Intl.DateTimeFormat("ar-PS-u-nu-latn", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(v));
}
export function d(v: string | null | undefined) {
  if (!v) return "—";
  if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return v.split("-").join("/");
  return new Intl.DateTimeFormat("ar-PS-u-nu-latn", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(v));
}
export function todayISO() {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
  return parts;
}
export function toLocalInput(iso: string) {
  const p = new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false })
    .formatToParts(new Date(iso));
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? "00";
  return `${g("year")}-${g("month")}-${g("day")}T${g("hour") === "24" ? "00" : g("hour")}:${g("minute")}`;
}
/** datetime-local value interpreted in the BUSINESS timezone -> ISO UTC */
export function fromLocalInput(v: string): string {
  const [date, time] = v.split("T");
  const [y, m, dd] = date.split("-").map(Number);
  const [hh, mi] = time.split(":").map(Number);
  const guess = Date.UTC(y, m - 1, dd, hh, mi);
  const asTz = new Date(new Date(guess).toLocaleString("en-US", { timeZone: TZ }));
  const asUtc = new Date(new Date(guess).toLocaleString("en-US", { timeZone: "UTC" }));
  return new Date(guess - (asTz.getTime() - asUtc.getTime())).toISOString();
}
