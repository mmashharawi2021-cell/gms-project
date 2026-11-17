"use client";
import { useState } from "react";
import { api, download, newKey } from "@/lib/api";
import { checkDecimal, fromLocalInput, money, todayISO } from "@/lib/format";
import { Button, ErrorBox, Field, Modal, useAction } from "@/components/ui";

const POSITIVE = /^\d{1,9}(\.\d{1,2})?$/;

/** BR-29: the manager records an ACTUAL receipt (full or partial). The idempotency key is fixed per dialog,
 * so a double click or a network retry can never create two receipts. */
export default function PaymentDialog({ open, subscriber, onClose, onDone }: { open: boolean; subscriber: any; onClose: () => void; onDone: () => void }) {
  const [amount, setAmount] = useState("");
  const [paidAt, setPaidAt] = useState(() => todayISO() + "T" + new Date().toTimeString().slice(0, 5));
  const [method, setMethod] = useState("cash");
  const [ref, setRef] = useState("");
  const [key] = useState(newKey);
  const [receipt, setReceipt] = useState<any>(null);
  const { busy, error, setError, run } = useAction();
  const err = amount ? checkDecimal(amount, POSITIVE, 2) : null;
  async function save() {
    if (!amount || err || /^0+(\.0+)?$/.test(amount.trim())) return setError({ message: err ?? "أدخل مبلغًا موجبًا" });
    const r: any = await run(() => api("payments", { body: { subscriber_id: subscriber.id, amount_ils: amount.trim(), paid_at: fromLocalInput(paidAt), method, reference: ref || null, idempotency_key: key } }));
    if (r) setReceipt(r);
  }
  if (receipt) {
    return (
      <Modal open={open} onClose={onDone} title="تم تسجيل الدفعة" footer={<><Button variant="primary" onClick={() => download(`payments/${receipt.payment.id}/receipt`, `${receipt.payment.receipt_no}.pdf`)}>إيصال PDF للطباعة</Button><Button onClick={onDone}>إغلاق</Button></>}>
        <dl className="kv">
          <dt>رقم الإيصال</dt><dd className="ltr">{receipt.payment.receipt_no}</dd>
          <dt>المشترك</dt><dd>{receipt.payment.subscriber_name} ({receipt.payment.subscription_no})</dd>
          <dt>المبلغ المقبوض</dt><dd>{money(receipt.payment.amount_ils)}</dd>
          <dt>المطلوب بعد الدفعة</dt><dd>{money(receipt.account.requested_whole_ils)}</dd>
          <dt>كسر مرحّل</dt><dd>{money(receipt.account.carry_fraction_ils)}</dd>
          <dt>رصيد دائن</dt><dd>{money(receipt.account.credit_balance_ils)}</dd>
        </dl>
      </Modal>
    );
  }
  return (
    <Modal open={open} onClose={onClose} title={`تسجيل دفعة — ${subscriber.full_name}`} footer={<><Button variant="primary" busy={busy} onClick={save}>تسجيل الدفعة</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <p>المطلوب حاليًا: <b>{money(subscriber.account?.requested_whole_ils ?? subscriber.requested_whole_ils)}</b> <span className="muted">— الرصيد الدقيق {money(subscriber.account?.balance_exact_ils ?? subscriber.balance_exact_ils)}</span></p>
        <Field label="المبلغ المقبوض فعليًا ₪" required error={err} hint="يُقبل دفع جزئي"><input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} autoFocus /></Field>
        <div className="grid grid-2">
          <Field label="تاريخ ووقت القبض" required><input type="datetime-local" value={paidAt} onChange={(e) => setPaidAt(e.target.value)} /></Field>
          <Field label="الطريقة"><select value={method} onChange={(e) => setMethod(e.target.value)}><option value="cash">نقدًا</option><option value="bank_transfer">تحويل بنكي</option><option value="other">أخرى</option></select></Field>
        </div>
        <Field label="مرجع (رقم إيصال ورقي/حوالة)"><input value={ref} onChange={(e) => setRef(e.target.value)} /></Field>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}
