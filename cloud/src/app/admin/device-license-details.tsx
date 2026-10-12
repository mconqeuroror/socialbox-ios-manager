"use client";
import { useState } from "react";
import { api, formatDate } from "@/lib/client";

export interface DeviceLicenseRow {
  id: string; kind: string; ownerUserId: string | null; owner: string | null;
  status: "active" | "revoked" | "expired" | "invalid" | "deleted";
  maxActivations: number; label: string; note: string; deletedAt: string | null;
  activations: { deviceId: string; deviceName: string; deviceBinding: string; activatedAt: string; lastCheckedAt: string | null }[];
  history: { id: string; at: string; action: string; deviceId?: string; actorUserId?: string; detail?: string }[];
}
export function DeviceLicenseDetails({ license, users, onChanged }: {
  license: DeviceLicenseRow; users: { id: string; email: string }[]; onChanged: () => Promise<void>;
}) {
  const [editing, setEditing] = useState(false), [label, setLabel] = useState(license.label), [note, setNote] = useState(license.note);
  const [owner, setOwner] = useState(license.ownerUserId ?? ""), [busy, setBusy] = useState(false), [error, setError] = useState<string | null>(null);
  async function update(body: object) {
    setBusy(true); setError(null);
    const result = await api(`/api/admin/licenses/${license.id}`, { method: "PATCH", body: JSON.stringify(body) });
    setBusy(false);
    if (!result.ok) { setError(result.error); return; }
    setEditing(false); await onChanged();
  }
  return <div className="mt-2 min-w-56 space-y-2 text-xs font-sans">
    <p className="font-semibold">{license.label || "Unlabelled key"}</p>
    <p className="text-slate-500">{license.kind === "device" ? "Device key" : "Legacy account key"} · owner {license.owner ?? "needs assignment"}</p>
    {license.note && <p className="max-w-xs whitespace-pre-wrap break-words text-slate-500">{license.note}</p>}
    <p>{license.activations.length}/{license.maxActivations} device activations · bindings stay locked</p>
    <details className="max-w-lg">
      <summary className="cursor-pointer font-medium">Bound devices and history</summary>
      {license.activations.length === 0 && <p className="py-2 text-slate-500">No device activated yet.</p>}
      <ul className="my-2 space-y-2">
        {license.activations.map((activation) => <li key={activation.deviceId} className="rounded bg-slate-50 p-2 dark:bg-slate-900">
          <p className="font-semibold">{activation.deviceName}</p>
          <p className="break-all font-mono">{activation.deviceId}</p>
          <p>Bound {formatDate(activation.activatedAt)}</p>
          <p>Last check: {activation.lastCheckedAt ? formatDate(activation.lastCheckedAt) : "never"}</p>
          <p className="break-all text-slate-500">Installation digest: {activation.deviceBinding}</p>
        </li>)}
      </ul>
      <ol className="space-y-1">
        {license.history.map((entry) => <li key={entry.id}>{formatDate(entry.at)} · {entry.action}
          {entry.deviceId ? ` · ${entry.deviceId}` : ""}{entry.actorUserId ? ` · by ${entry.actorUserId}` : ""}{entry.detail ? ` · ${entry.detail}` : ""}</li>)}
      </ol>
    </details>
    {!license.deletedAt && <div className="flex flex-wrap gap-2">
      <button type="button" className="btn-secondary !px-2 !py-1 !text-xs" disabled={busy} onClick={() => {
        setLabel(license.label); setNote(license.note); setOwner(license.ownerUserId ?? ""); setEditing(!editing);
      }}>Edit label / owner</button>
      {license.status === "revoked" && <button type="button" className="btn-secondary !px-2 !py-1 !text-xs" disabled={busy}
        onClick={() => update({ action: "enable" })}>Re-enable</button>}
      <button type="button" className="btn-danger !px-2 !py-1 !text-xs" disabled={busy} onClick={() => {
        if (window.confirm("Delete this key permanently? Device access is denied at its next online check. Containers, binding records and history are retained.")) void update({ action: "delete" });
      }}>Delete key</button>
    </div>}
    {editing && !license.deletedAt && <form className="grid gap-2" onSubmit={(event) => {
      event.preventDefault(); void update({ label, note, ...(owner ? { ownerUserId: owner } : {}) });
    }}>
      <label>Label<input className="input" value={label} onChange={(event) => setLabel(Array.from(event.target.value).slice(0, 80).join(""))} /></label>
      <label>Note<textarea className="input" value={note} onChange={(event) => setNote(Array.from(event.target.value).slice(0, 200).join(""))} /></label>
      <label>Owner<select className="input" value={owner} disabled={license.activations.length > 0} onChange={(event) => setOwner(event.target.value)}>
        <option value="">Unassigned legacy key</option>
        {users.map((user) => <option key={user.id} value={user.id}>{user.email}</option>)}
      </select></label>
      <button className="btn-primary !py-1 !text-xs" disabled={busy}>Save details</button>
    </form>}
    {error && <p role="alert" className="error-text">{error}</p>}
  </div>;
}
