import { releaseCandidates, releaseState } from "@/lib/socialbox-releases";
import { publicRelease } from "@/lib/socialbox-release-policy";
export const dynamic = "force-dynamic";
export default async function UpdatesPage() {
  let release, unavailable = false;
  try { const state = await releaseState(); release = publicRelease(releaseCandidates().find(c => c.id === state.current), state); } catch { unavailable = true; }
  return <main className="mx-auto max-w-2xl space-y-7 px-6 py-14">
    <a className="text-sm font-semibold tracking-widest text-emerald-300" href="/updates">SOCIALBOX</a>
    <h1 className="text-4xl font-semibold tracking-tight">App updates</h1>
    {release?.available ? <>
      <section className="card space-y-3 p-6"><p className="badge-green">Released</p><h2 className="text-xl font-semibold">{release.packageVersion}</h2><p className="whitespace-pre-wrap text-slate-300">{release.notes}</p>
        <p className="text-sm text-slate-400">Rootless iOS 16 or later. Upgrade from {release.supportedFrom?.join(", ")} only.</p></section>
      <ol className="list-decimal space-y-4 pl-5 text-slate-300"><li>Export a backup of your containers and keep a copy outside the phone. Stop the active app session.</li>
        <li>In Sileo, add the source below, refresh Sources, then find SocialBox and choose <strong>Upgrade</strong>.</li>
        <li>Open SocialBox. Confirm your container names, accounts, identity and proxy settings are unchanged before continuing.</li></ol>
      <label className="block text-sm text-slate-400">Sileo source<input className="input mt-2" aria-label="Sileo source" readOnly value="https://redditspoof.vercel.app/apt/socialbox/" /></label>
      <p className="text-sm text-blue-200">Do not uninstall, purge or reset the app to update it. A different installed version needs a tested upgrade path; contact support first.</p>
      <details className="text-sm text-slate-400"><summary>Package verification</summary><p className="mt-3 break-all font-mono">SHA-256: {release.sha256}</p><a className="mt-3 block text-emerald-300" href="/apt/socialbox/key.asc">Repository signing key</a></details>
    </> : <section className="card space-y-3 p-6"><h2 className="text-xl font-semibold">{unavailable ? "Update information is unavailable" : "No public update yet"}</h2><p className="text-slate-400">{unavailable ? "Please try again later or contact support. Keep your current installation and containers." : "The next version is being tested. Keep your current installation and containers. An update notice will appear in supported versions of SocialBox after a release is approved."}</p></section>}
    <p className="text-sm text-slate-400">Updates are announced automatically in supported versions. You approve installation in Sileo.</p>
    <a className="inline-block text-emerald-300" href="https://t.me/sctweaks" target="_blank" rel="noreferrer">Contact @sctweaks ↗</a>
  </main>;
}
