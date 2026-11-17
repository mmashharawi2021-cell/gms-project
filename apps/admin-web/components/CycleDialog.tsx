"use client";
import { useState } from "react";
import { api } from "@/lib/api";
import { Button, ErrorBox, Field, Modal, useAction } from "@/components/ui";

export function CycleDialog({ cycle, onClose, onDone }: { cycle?: any; onClose: () => void; onDone: () => void }) {
  const [f, setF] = useState({ label: cycle?.label ?? "", starts_on: cycle?.starts_on ?? "", ends_on: cycle?.ends_on ?? "" });
  const { busy, error, run } = useAction();
  const save = () => run(() => cycle ? api(`cycles/${cycle.id}`, { method: "PUT", body: f }) : api("cycles", { body: f }), "تم الحفظ").then((r) => r && onDone());
  return (
    <Modal open onClose={onClose} title={cycle ? "تعديل الدورة" : "دورة جديدة"} footer={<><Button variant="primary" busy={busy} onClick={save}>حفظ</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <Field label="اسم الدورة" required hint="مثال: الأسبوع 46 — 2026"><input value={f.label} onChange={(e) => setF({ ...f, label: e.target.value })} /></Field>
        <div className="grid grid-2">
          <Field label="من" required><input type="date" value={f.starts_on} onChange={(e) => setF({ ...f, starts_on: e.target.value })} /></Field>
          <Field label="إلى" required><input type="date" value={f.ends_on} onChange={(e) => setF({ ...f, ends_on: e.target.value })} /></Field>
        </div>
        <p className="muted">تُنشأ الدورة كمسودة، ثم تُفتح بعد إغلاق الدورة السابقة.</p>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}
