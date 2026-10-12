"use client";
import { useState } from "react";
import type { InstallationSource } from "@/lib/installation";

export default function SourceCard({ source, title, description }: { source: InstallationSource; title: string; description: string }) {
  const [message, setMessage] = useState("");
  async function copy() {
    try { await navigator.clipboard.writeText(source.url!); setMessage("Adresa zdroja je skopírovaná."); }
    catch { setMessage("Kopírovanie nie je dostupné. Označ a skopíruj adresu vyššie."); }
  }
  return <section className="flex flex-col rounded-2xl border border-slate-700 bg-slate-900 p-6 sm:p-8">
    <div className="mb-6 flex items-center justify-between gap-3">
      <span className="rounded-full bg-slate-800 px-3 py-1 text-xs font-semibold uppercase tracking-wider text-slate-300">{source.architecture === "iphoneos-arm64" ? "Rootless" : "Rootful"}</span>
      <span className={`text-sm ${source.available ? "text-emerald-400" : "text-slate-400"}`}>{source.available ? `Verzia ${source.version}` : "Zatiaľ nepublikované"}</span>
    </div>
    <h2 className="text-2xl font-bold tracking-tight text-white">{title}</h2>
    <p className="mt-3 flex-1 text-sm leading-6 text-slate-400">{description}</p>
    {source.available && source.url && source.sileoURL ? <>
      <a href={source.sileoURL} className="btn-primary mt-7 justify-center !py-3 text-center">Pridať do Sileo <span aria-hidden="true">↗</span></a>
      <p className="mt-3 text-xs leading-5 text-slate-400">Otvorí Sileo a pridanie zdroja. Potom vyhľadaj RedditBox a nainštaluj balík.</p>
      <div className="mt-5 rounded-xl border border-slate-700 bg-slate-950 p-3">
        <p className="mb-2 text-xs text-slate-500">Adresa zdroja</p>
        <code className="block select-all break-all text-xs leading-5 text-slate-200">{source.url}</code>
      </div>
      <button type="button" onClick={copy} className="btn-secondary mt-3 justify-center !py-2.5">Skopírovať adresu zdroja</button>
      <p role="status" aria-live="polite" className="mt-2 min-h-5 text-xs text-emerald-300">{message}</p>
    </> : <p className="mt-7 rounded-xl border border-slate-700 p-4 text-sm leading-6 text-slate-300">Tento variant ešte nemá publikovaný inštalačný zdroj. Odkaz sa zobrazí po dokončení publikovania.</p>}
  </section>;
}
