"use client";
import { useState } from "react";
import { Button, ErrorBox, Field, Modal, useAction } from "@/components/ui";

export function ReasonDialog({ open, title, note, noReason, onClose, onSubmit, onDone }: { open: boolean; title: string; note?: string; noReason?: boolean; onClose: () => void; onSubmit: (reason: string) => Promise<any>; onDone: () => void }) {
  const [reason, setReason] = useState("");
  const { busy, error, run } = useAction();
  return (
    <Modal open={open} onClose={onClose} title={title} footer={<><Button variant="primary" busy={busy} disabled={!noReason && !reason.trim()} onClick={async () => { if (await run(() => onSubmit(reason.trim()).then(() => true), "تم")) { setReason(""); onDone(); } }}>تأكيد</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        {note && <p className="muted">{note}</p>}
        {!noReason && <Field label="السبب" required><textarea rows={3} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>}
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

