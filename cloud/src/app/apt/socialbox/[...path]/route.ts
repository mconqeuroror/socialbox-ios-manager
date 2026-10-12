import { releaseCandidates, releaseState } from "@/lib/socialbox-releases";
import { publicRelease } from "@/lib/socialbox-release-policy";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
/** Only promoted, immutable snapshots are served. A candidate is never a stable repository. */
export async function GET(_req: Request, { params }: { params: { path: string[] } }) {
  const headers = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
  try {
    const state = await releaseState(), candidates = releaseCandidates();
    const current = candidates.find(c => c.id === state.current);
    if (!publicRelease(current, state).available || !current) return new Response("No public release", { status: 404, headers });
    const pathname = params.path.join("/");
    const published = candidates.filter(c => state.history.some(e => e.candidateID === c.id && e.sha256 === c.sha256));
    for (const c of published) {
      if (pathname === `pool/${c.sha256}/socialbox_${c.sequence}_iphoneos-arm64.deb` && c.artifactURL)
        return new Response(null, { status: 302, headers: { ...headers, Location: c.artifactURL } });
    }
    const file = pathname.startsWith("by-hash/") ? published.map(c => c.files[pathname]).find(Boolean) : current.files[pathname];
    if (!file) return new Response("Not found", { status: 404, headers });
    const type = pathname === "Packages.gz" ? "application/gzip" : pathname === "Release.gpg" ? "application/pgp-signature" : "text/plain; charset=utf-8";
    return new Response(Buffer.from(file.base64, "base64"), { headers: { ...headers, "Content-Type": type } });
  } catch { return new Response("Repository temporarily unavailable", { status: 503, headers }); }
}
