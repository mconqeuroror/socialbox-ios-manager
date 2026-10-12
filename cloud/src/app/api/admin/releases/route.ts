import { NextResponse } from "next/server";
import { getConsoleOwnerFromRequest } from "@/lib/console-auth";
import { releaseCandidates, releaseState, mutateRelease } from "@/lib/socialbox-releases";
import { attestRelease, promoteRelease, releaseBlockers, type ReleaseCheck } from "@/lib/socialbox-release-policy";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
const json = (body: unknown, status = 200) => NextResponse.json(body, { status, headers: { "Cache-Control": "private, no-store" } });
export async function GET(req: Request) {
  const user = await getConsoleOwnerFromRequest(req);
  if (!user) return json({ error: "Owner access required" }, 403);
  try {
    const state = await releaseState();
    return json({ state, candidates: releaseCandidates().map(({ files, ...candidate }) => ({ ...candidate,
      blockers: releaseBlockers({ ...candidate, files }, state) })) });
  } catch { return json({ error: "Could not read releases" }, 503); }
}
export async function POST(req: Request) {
  const user = await getConsoleOwnerFromRequest(req);
  if (!user) return json({ error: "Owner access required" }, 403);
  if (req.headers.get("origin") !== new URL(req.url).origin || !req.headers.get("content-type")?.startsWith("application/json"))
    return json({ error: "A same-origin JSON request is required" }, 403);
  let body;
  try { const raw = await req.text(); if (raw.length > 8192) throw new Error(); body = JSON.parse(raw); }
  catch { return json({ error: "Invalid release request" }, 400); }
  if (!body || typeof body !== "object" || Array.isArray(body)) return json({ error: "Invalid release request" }, 400);
  try {
    const candidates = releaseCandidates(), candidate = candidates.find(c => c.id === body.candidateID);
    if (!candidate || body.sha256 !== candidate.sha256) return json({ error: "Candidate or package hash changed. Refresh first." }, 409);
    if (body.action !== "attest" && body.action !== "release") return json({ error: "Unknown release action" }, 400);
    if (body.action === "release" && !Number.isInteger(body.revision)) return json({ error: "Release revision required" }, 400);
    const at = new Date().toISOString();
    const state = await mutateRelease(s => body.action === "attest"
      ? attestRelease(s, candidate, body.checks as Record<ReleaseCheck, string>, user.id, at)
      : promoteRelease(s, candidate, candidates, body.revision, user.id, at));
    return json({ state });
  } catch (error) { return json({ error: error instanceof Error ? error.message : "Release could not be saved" }, 409); }
}
