"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { api } from "@/lib/client";
export default function LoginPage() {
  const router=useRouter();
  const [username,setUsername]=useState(""),[password,setPassword]=useState("");
  const [error,setError]=useState<string|null>(null),[busy,setBusy]=useState(false);
  async function submit(event:React.FormEvent) {
    event.preventDefault(); if(busy) return;setBusy(true);setError(null);
    const result=await api<{user:{consoleOwner:boolean}}>("/api/auth/owner-login",{method:"POST",body:JSON.stringify({username,password})});
    if(!result.ok){setBusy(false);setError(result.error);return;}
    if(!result.data.user.consoleOwner){await api("/api/auth/logout",{method:"POST"});setBusy(false);setError("Owner access is required.");return;}
    router.replace("/admin");router.refresh();
  }
  return <main className="grid min-h-screen place-items-center px-6 py-10"><div className="w-full max-w-sm">
    <div className="mb-8"><span className="mb-6 grid h-12 w-12 place-items-center rounded-2xl bg-emerald-300 text-xl font-bold text-slate-950" aria-hidden>S</span><h1 className="text-3xl font-semibold tracking-tight">SocialBox</h1><p className="mt-2 text-slate-400">Sign in to manage license keys.</p></div>
    <form onSubmit={submit} className="card space-y-5 p-6"><label className="label">Username<input className="input mt-2" value={username} autoComplete="username" required onChange={e=>setUsername(e.target.value)} /></label><label className="label">Password<input className="input mt-2" type="password" value={password} autoComplete="current-password" required onChange={e=>setPassword(e.target.value)} /></label>
      {error&&<p role="alert" className="error-text">{error}</p>}<button className="btn-primary w-full" disabled={busy}>{busy?"Signing in…":"Sign in"}</button></form>
    <p className="mt-6 text-center text-xs text-slate-500">Private admin console</p>
  </div></main>;
}
