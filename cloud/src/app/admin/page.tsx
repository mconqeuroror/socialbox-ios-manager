"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { api, formatDate } from "@/lib/client";
import { DeviceLicenseDetails, type DeviceLicenseRow } from "./device-license-details";

type User = { id: string; email: string; username?: string; role: string; consoleOwner?: boolean };
type License = DeviceLicenseRow & { createdAt: string; expiresAt: string | null; revoked: boolean; valid: boolean; keyIdPrefix?: string };
export default function AdminPage() {
  const router = useRouter();
  const [me, setMe] = useState<User | null>(null), [loading, setLoading] = useState(true);
  const [licenses, setLicenses] = useState<License[]>([]), [users, setUsers] = useState<User[]>([]);
  const [error, setError] = useState<string | null>(null), [busy, setBusy] = useState(false);
  const [createOpen, setCreateOpen] = useState(false), [keys, setKeys] = useState<string[]>([]);
  const [copied, setCopied] = useState(false), [copyError, setCopyError] = useState(false);
  const [label, setLabel] = useState("");
  const [count, setCount] = useState(1), [note, setNote] = useState(""), [owner, setOwner] = useState("");
  const [search, setSearch] = useState(""), [state, setState] = useState("all"), [revoking, setRevoking] = useState<string | null>(null);
  const load = useCallback(async () => {
    const [l, u] = await Promise.all([api<{ licenses: License[] }>("/api/admin/licenses"), api<{ users: User[] }>("/api/admin/users")]);
    if (!l.ok || !u.ok) { setError("Could not refresh keys. Try again."); return; }
    setLicenses(l.data.licenses); setUsers(u.data.users); setError(null);
  }, []);
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const result = await api<{ user: User }>("/api/auth/me");
      if (cancelled) return;
      if (!result.ok) { router.replace("/login"); return; }
      setMe(result.data.user);
      if (result.data.user.consoleOwner) await load();
      if (!cancelled) setLoading(false);
    })();
    return () => { cancelled = true; };
  }, [load, router]);
  const visible = useMemo(() => licenses.filter(l => (state === "deleted" ? !!l.deletedAt : !l.deletedAt)
    && (state === "all" || l.status === state)
    && `${l.label} ${l.keyIdPrefix || l.id.slice(0,8)} ${l.owner || ""}`.toLowerCase().includes(search.toLowerCase())), [licenses, state, search]);
  async function logout() {
    const r = await api("/api/auth/logout", { method: "POST" });
    if (!r.ok) { setError("Sign out failed. Please try again."); return; }
    setKeys([]); router.replace("/login"); router.refresh();
  }
  async function create(event: React.FormEvent) {
    event.preventDefault(); if (busy || keys.length) return;
    setBusy(true); setError(null);
    const result = await api<{ licenses: { key: string }[] }>("/api/admin/licenses", { method: "POST", body: JSON.stringify({
      count, label, note, ...(owner ? { ownerUserId: owner } : {})
    }) });
    setBusy(false);
    if (!result.ok) { setError(result.error); return; }
    setKeys(result.data.licenses.map(l => l.key)); setCopied(false); setCopyError(false); setCreateOpen(false);
    setLabel(""); setNote(""); await load();
  }
  async function revoke(id: string) {
    if (!window.confirm("Revoke this key? Access stops at the next online check; cached offline access can last up to 72 hours.")) return;
    setRevoking(id);
    const result = await api(`/api/admin/licenses/${id}/revoke`, { method: "POST" });
    setRevoking(null);
    if (!result.ok) { setError(result.error); return; }
    await load();
  }
  if (loading) return <main className="grid min-h-screen place-items-center"><p role="status">Loading your keys…</p></main>;
  if (!me?.consoleOwner) return <main className="grid min-h-screen place-content-center gap-4 px-6"><h1 className="text-2xl font-semibold">Owner access required</h1><p>This console is private.</p><button className="btn-secondary" onClick={logout}>Sign out</button></main>;
  return <div className="min-h-screen">
    <header className="border-b border-slate-800"><div className="mx-auto flex max-w-4xl items-center justify-between gap-4 px-5 py-5">
      <a href="/admin" className="flex items-center gap-3 font-semibold"><span className="grid h-9 w-9 place-items-center rounded-xl bg-emerald-300 text-slate-950" aria-hidden>S</span>SocialBox <span className="hidden text-sm font-normal text-slate-500 sm:inline">/ Admin</span></a>
      <div className="flex items-center gap-5"><button className="text-sm text-slate-400 hover:text-white" onClick={logout}>Sign out</button></div>
    </div></header>
    <main className="mx-auto max-w-4xl space-y-6 px-5 py-10">
      <div className="flex flex-wrap items-end justify-between gap-4"><div><p className="mb-2 text-xs font-semibold uppercase tracking-widest text-emerald-300">Access management</p><h1 className="text-4xl font-semibold tracking-tight">License keys</h1><p className="mt-3 text-sm text-slate-400">Create keys and manage device access.</p></div>
        <button className="btn-primary" disabled={keys.length > 0} onClick={() => setCreateOpen(!createOpen)}>{createOpen ? "Close form" : "+ Create key"}</button>
      </div>
      {error && <div role="alert" className="card flex flex-wrap items-center justify-between gap-3 border-red-900 p-4"><p className="text-red-300">{error}</p><button className="btn-secondary !py-2" onClick={load}>Retry</button></div>}
      {keys.length > 0 && <section className="card border-emerald-800 p-6" aria-label="New keys"><h2 className="text-xl font-semibold">Save your {keys.length === 1 ? "key" : "keys"}</h2><p className="mt-2 text-sm text-slate-400">Shown once. Copy before closing this page.</p>
        <div className="my-4 space-y-2">{keys.map(key => <code className="block select-all break-all rounded-lg bg-slate-950 p-3 text-emerald-200" key={key}>{key}</code>)}</div>
        <div className="flex flex-wrap gap-3"><button className="btn-primary" onClick={async () => { try { await navigator.clipboard.writeText(keys.join("\n")); setCopied(true); setCopyError(false); } catch { setCopyError(true); } }}>{copied ? "Copied" : "Copy keys"}</button><button className="btn-secondary" onClick={() => setKeys([])}>I saved my keys</button></div>
        {copyError && <p role="alert" className="mt-3 text-sm text-blue-300">Clipboard unavailable. Select the key above and copy it manually.</p>}
      </section>}
      {createOpen && <section className="card p-6"><h2 className="text-xl font-semibold">New key</h2><p className="mt-2 text-sm text-slate-400">No expiry. One device. Enter the key once in the app; license checks continue.</p><form onSubmit={create} className="mt-5 space-y-5">
        <label className="label block">Name<input className="input mt-2" placeholder="e.g. Alex’s iPhone" value={label} maxLength={80} onChange={e => setLabel(e.target.value)} /></label>
        <details><summary className="cursor-pointer text-sm text-slate-400">More options</summary><div className="mt-4 grid gap-4 sm:grid-cols-2">
          <label className="label">Number of keys<input className="input mt-2" type="number" min={1} max={100} required value={count} onChange={e => setCount(Number(e.target.value))} /></label>
          <label className="label">Owner<select className="input mt-2" value={owner} onChange={e => setOwner(e.target.value)}><option value="">My account</option>{users.map(u => <option key={u.id} value={u.id}>{u.email}</option>)}</select></label>
          <label className="label sm:col-span-2">Private note<textarea className="input mt-2" value={note} maxLength={200} onChange={e => setNote(e.target.value)} /></label>
        </div></details><button className="btn-primary" disabled={busy}>{busy ? "Creating…" : "Generate key"}</button>
      </form></section>}
      <section aria-label="Saved keys" className="space-y-3">
        <div className="flex flex-wrap gap-3"><input className="input min-w-0 flex-1 !w-auto" aria-label="Search keys" placeholder="Search name or key ID…" value={search} onChange={e => setSearch(e.target.value)} />
          <select className="input !w-auto" aria-label="Key status" value={state} onChange={e => setState(e.target.value)}>{["all","active","revoked","expired","deleted"].map(s => <option value={s} key={s}>{s === "all" ? "All keys" : s.charAt(0).toUpperCase()+s.slice(1)}</option>)}</select></div>
        <p className="py-1 text-xs text-slate-500">{visible.length} {visible.length === 1 ? "key" : "keys"}</p>
        {visible.length === 0 && <div className="card p-10 text-center text-slate-400">{search || state !== "all" ? "No matching keys." : "No keys yet. Create your first key above."}</div>}
        {visible.map(l => <article className="card p-5" key={l.id}>
          <div className="flex flex-wrap items-start justify-between gap-3"><div className="min-w-0"><h2 className="break-words font-semibold">{l.label || "Unnamed key"}</h2><p className="mt-1 font-mono text-xs text-slate-500">ID {l.keyIdPrefix || l.id.slice(0,8)}</p></div><span className={l.status === "active" ? "badge-green" : "badge-slate"}>{l.status}</span></div>
          <p className="mt-3 text-sm text-slate-400">{l.activations.length} / {l.maxActivations} devices · {l.expiresAt ? `Expires ${formatDate(l.expiresAt)}` : "No expiry"}</p>
          <details className="mt-4"><summary className="cursor-pointer text-sm font-medium text-emerald-300">Manage key</summary><div className="mt-4 border-t border-slate-800 pt-3">
            <DeviceLicenseDetails license={l} users={users} onChanged={load} />
            {!l.deletedAt && !l.revoked && <button className="btn-danger mt-3 !px-3 !py-2 !text-sm" disabled={revoking === l.id} onClick={() => revoke(l.id)}>{revoking === l.id ? "Revoking…" : "Revoke key"}</button>}
          </div></details>
        </article>)}
      </section>
      <footer className="flex flex-wrap justify-between gap-3 border-t border-slate-800 pt-6 text-xs text-slate-500"><span>SocialBox · Private admin</span><a className="hover:text-emerald-300" href="https://t.me/sctweaks" target="_blank" rel="noreferrer">Contact @sctweaks ↗</a></footer>
    </main>
  </div>;
}
