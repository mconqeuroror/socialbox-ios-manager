import { releaseCandidates, releaseState } from "@/lib/socialbox-releases";
import { publicRelease } from "@/lib/socialbox-release-policy";

export const dynamic = "force-dynamic";
const source = "https://redditspoof.vercel.app/apt/socialbox/";

export default async function InstallPage() {
  let release, unavailable = false;
  try {
    const state = await releaseState();
    release = publicRelease(releaseCandidates().find(candidate => candidate.id === state.current), state);
  } catch { unavailable = true; }
  return <main className="mx-auto max-w-2xl space-y-7 px-6 py-14">
    <a className="text-sm font-semibold tracking-widest text-emerald-300" href="/install">SOCIALBOX</a>
    <h1 className="text-4xl font-semibold tracking-tight">Get SocialBox</h1>
    <p className="text-slate-300">Install through Sileo on a supported jailbroken iPhone, then activate with the license code provided by @sctweaks.</p>
    {release?.available ? <section className="card space-y-4 p-6">
      <h2 className="text-xl font-semibold">Update an existing installation</h2>
      <p className="text-slate-300">Version {release.packageVersion} is available for rootless iOS 16 or later, from {release.supportedFrom?.join(", ")}.</p>
      <p className="text-sm text-blue-200">This channel currently supports upgrades. A package for a new client installation is still being tested.</p>
      <a className="btn-primary inline-block" href={`sileo://source/${source}`}>Add repository to Sileo</a>
      <label className="block text-sm text-slate-400">Repository URL<input className="input mt-2" aria-label="Repository URL" readOnly value={source} /></label>
      <p className="text-sm text-slate-400">Back up your containers before upgrading. Keep your existing app and data.</p>
    </section> : <section className="card space-y-3 p-6">
      <h2 className="text-xl font-semibold">{unavailable ? "Download status is unavailable" : "Client build is being tested"}</h2>
      <p className="text-slate-400">{unavailable ? "Please try again later or contact @sctweaks." : "The installation link will appear here when a client package is ready. Contact @sctweaks for trial access."}</p>
    </section>}
    <a className="inline-block text-emerald-300" href="https://t.me/sctweaks" target="_blank" rel="noreferrer">Contact @sctweaks ↗</a>
  </main>;
}
