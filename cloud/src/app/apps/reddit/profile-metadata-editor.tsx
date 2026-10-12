"use client";

import { useState } from "react";
import { api } from "@/lib/client";
import { PROFILE_ROLES, profileNoteLength, type ProfileRole } from "@/lib/profile-metadata";

export interface EditableProfileMetadata {
  profileId: string;
  appType?: string;
  role: ProfileRole;
  notes: string;
  metadataRevision: number;
}

const ROLE_COLORS: Record<ProfileRole, string> = {
  signup: "bg-sky-100 text-sky-800 dark:bg-sky-950 dark:text-sky-200",
  warmup: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-200",
  spam: "bg-violet-100 text-violet-800 dark:bg-violet-950 dark:text-violet-200",
  default: "bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-200",
};

export function ProfileRoleTag({ role }: { role: ProfileRole }) {
  return <span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-semibold ${ROLE_COLORS[role]}`}>{role}</span>;
}

export function ProfileMetadataEditor({ profile, onSaved }: {
  profile: EditableProfileMetadata; onSaved: (value: EditableProfileMetadata) => void;
}) {
  // Keep the original revision while editing: refreshes cannot silently overwrite a draft.
  const [draft, setDraft] = useState<EditableProfileMetadata | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (!draft) return <div className="w-full">
    {profile.notes && <p className="mb-2 whitespace-pre-wrap break-words text-sm text-slate-600 dark:text-slate-300">{profile.notes}</p>}
    <button type="button" className="btn-secondary !px-3 !py-1.5 !text-sm" onClick={() => { setDraft({ ...profile }); setError(null); }}>
      Edit role and notes
    </button>
  </div>;
  async function save(event: React.FormEvent) {
    event.preventDefault();
    if (!draft) return;
    setBusy(true); setError(null);
    const result = await api<{ profile: EditableProfileMetadata }>("/api/profiles", {
      method: "PATCH", body: JSON.stringify({ profileId: draft.profileId, appType: draft.appType ?? "reddit", role: draft.role,
        notes: draft.notes, metadataRevision: draft.metadataRevision }),
    });
    setBusy(false);
    if (!result.ok) { setError(result.error); return; }
    onSaved(result.data.profile); setDraft(null);
  }
  return <form className="grid w-full gap-2 rounded-lg bg-slate-50 p-3 dark:bg-slate-900" onSubmit={save}>
    <label className="text-xs font-medium" htmlFor={`role-${profile.profileId}`}>Role (label only)</label>
    <select id={`role-${profile.profileId}`} className="input" value={draft.role} disabled={busy}
      onChange={(event) => setDraft({ ...draft, role: event.target.value as ProfileRole })}>
      {PROFILE_ROLES.map((role) => <option key={role} value={role}>{role}</option>)}
    </select>
    <label className="text-xs font-medium" htmlFor={`notes-${profile.profileId}`}>Notes</label>
    <textarea id={`notes-${profile.profileId}`} className="input min-h-20" value={draft.notes} disabled={busy}
      onChange={(event) => setDraft({ ...draft, notes: Array.from(event.target.value).slice(0, 200).join("") })}
      aria-describedby={`notes-count-${profile.profileId}`} />
    <p id={`notes-count-${profile.profileId}`} className="text-xs text-slate-500">{profileNoteLength(draft.notes)}/200 characters. Role and notes do not change isolation or traffic policy.</p>
    {error && <p role="alert" className="error-text">{error} Your draft is preserved. Cancel, refresh, then edit again to use the latest version.</p>}
    <div className="flex gap-2">
      <button type="submit" className="btn-primary !px-3 !py-1.5 !text-sm" disabled={busy}>{busy ? "Saving…" : "Save metadata"}</button>
      <button type="button" className="btn-secondary !px-3 !py-1.5 !text-sm" disabled={busy} onClick={() => setDraft(null)}>Cancel</button>
    </div>
  </form>;
}
