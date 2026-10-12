"use client";
import { useCallback, useEffect, useState } from "react";
import { api, formatDate } from "@/lib/client";
import { RELEASE_CHECKS, type Candidate, type ReleaseCheck, type ReleaseState } from "@/lib/socialbox-release-policy";
const labels: Record<ReleaseCheck, string> = {
  backup_restore: "Backup and restore", upgrade_data: "Upgrade preserves data", launch_switch: "Launch and switch A → B → A",
  proxy_failure: "Proxy failure blocks direct fallback", license_activation: "Customer license activation",
};
type PublicCandidate = Omit<Candidate, "files">;
type Data = { state: ReleaseState; candidates: PublicCandidate[] };
export default function ReleasesPage() {
  const [data, setData] = useState<Data | null>(null), [error, setError] = useState(""), [busy, setBusy] = useState(false);
  const [selected, setSelected] = useState(""), [checks, setChecks] = useState({} as Record<ReleaseCheck, string>);
  const load = useCallback(async () => { const result = await api<Data>("/api/admin/releases");
    if (result.ok) { setData(result.data); setError(""); } else setError(result.error); }, []);
  useEffect(() => { void load(); }, [load]);
  async function submit(candidate: PublicCandidate, action: "attest" | "release") {
    if (busy || !data) return;
    if (action === "release" && !window.confirm(`Release ${candidate.packageVersion}? Customers on the supported previous version will be offered this exact tested package. No rebuild occurs.`)) return;
    setBusy(true); setError("");
    const result = await api("/api/admin/releases", { method: "POST", body: JSON.stringify({ action, candidateID: candidate.id,
      sha256: candidate.sha256, revision: data.state.revision, ...(action === "attest" ? { checks } : {}) }) });
    setBusy(false);
    if (!result.ok) { setError(result.error); return; }
    setSelected(""); setChecks({} as Record<ReleaseCheck, string>); await load();
  }
  return <main className="mx-auto max-w-3xl space-y-7 px-5 py-10">
    <nav className="flex justify-between text-sm"><a className="text-emerald-300" href="/admin">← License keys</a><a className="text-slate-400" href="/updates">Customer update page ↗</a></nav>
    <div><p className="text-xs font-semibold uppercase tracking-widest text-emerald-300">SocialBox / Releases</p><h1 className="mt-3 text-4xl font-semibold">Test first. Release once.</h1><p className="mt-4 text-slate-400">Prepare a candidate on the Mac, install that exact package on your iPhone, record the results, then release it. Customers receive an update notice and approve Upgrade in Sileo.</p></div>
    {error && <div className="card space-y-3 border-red-900 p-5" role="alert"><p className="text-red-300">{error}</p><button className="btn-secondary" onClick={load}>Refresh</button></div>}
    {!data && !error && <p role="status">Loading releases…</p>}
    {data && <><section className="card p-5"><h2 className="font-semibold">Public version</h2><p className="mt-2 text-slate-400">{data.candidates.find(c => c.id === data.state.current)?.packageVersion || "No approved release"}</p></section>
      {!data.candidates.length && <section className="card space-y-3 p-6"><h2 className="text-xl font-semibold">Prepare the first candidate</h2><p className="text-slate-400">No signed candidate is registered in this deployment. The Mac release preparation tool adds the exact package, compatibility limits and signed repository. A build is not a device test.</p></section>}
      {[...data.candidates].sort((a,b) => b.sequence-a.sequence).map(c => {
        const receipt = data.state.receipts.find(r => r.candidateID === c.id && r.sha256 === c.sha256), released = c.id === data.state.current;
        return <article className="card space-y-4 p-6" key={c.id}>
          <div className="flex flex-wrap items-center justify-between gap-3"><h2 className="text-xl font-semibold">{c.packageVersion}</h2><span className={released ? "badge-green" : "badge-slate"}>{released ? "Public" : "Test candidate"}</span></div>
          <p className="whitespace-pre-wrap text-slate-300">{c.notes}</p><p className="text-sm text-slate-400">Rootless only · Upgrade from {c.supportedFrom.join(", ")} · {(c.size/1048576).toFixed(1)} MB</p>
          <details className="text-sm text-slate-400"><summary>Exact package</summary><p className="mt-3 break-all font-mono">SHA-256 {c.sha256}</p><p className="mt-2 font-mono">Commit {c.commit.slice(0,12)}</p>{c.artifactURL && <a className="mt-3 block text-emerald-300" href={c.artifactURL}>Download test package</a>}</details>
          {c.blockers.length > 0 && <div className="rounded-xl bg-blue-950/40 p-4"><p className="font-medium text-blue-200">Release blocked</p><ul className="mt-2 list-disc space-y-2 pl-5 text-sm text-blue-100">{c.blockers.map(b => <li key={b}>{b}</li>)}</ul></div>}
          {receipt && <p className="text-sm text-slate-400">Device results recorded {formatDate(receipt.at)}. These are operator observations, not proof of complete isolation.</p>}
          {!released && <div className="flex flex-wrap gap-3"><button className="btn-secondary" disabled={busy} onClick={() => { setSelected(selected === c.id ? "" : c.id); setChecks(receipt?.checks || {} as Record<ReleaseCheck,string>); }}>Record iPhone test</button><button className="btn-primary" disabled={busy || c.blockers.length > 0} onClick={() => submit(c,"release")}>{busy ? "Saving…" : "Release update"}</button></div>}
          {selected === c.id && <form className="space-y-4 border-t border-slate-700 pt-5" onSubmit={e => { e.preventDefault(); void submit(c,"attest"); }}>
            <p className="text-sm text-slate-400">Record actual PASS results, the installed predecessor and the backup reference. Do not enter passwords, license keys or account tokens. Leave a failing check unsubmitted.</p>
            {RELEASE_CHECKS.map(k => <label className="block text-sm" key={k}>{labels[k]}<textarea required minLength={12} maxLength={1000} className="input mt-2" value={checks[k] || ""} placeholder="Observed result and evidence reference…" onChange={e => setChecks({ ...checks, [k]: e.target.value })}/></label>)}
            <button className="btn-secondary" disabled={busy}>Save passed test results</button>
          </form>}
        </article>;
      })}</>}
  </main>;
}
