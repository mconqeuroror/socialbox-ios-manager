import { NextResponse } from "next/server";
import { releaseCandidates, releaseState } from "@/lib/socialbox-releases";
import { publicRelease } from "@/lib/socialbox-release-policy";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET() {
  try {
    const state = await releaseState();
    return NextResponse.json(publicRelease(releaseCandidates().find(c => c.id === state.current), state), { headers: { "Cache-Control": "no-store" } });
  } catch { return NextResponse.json({ error: "Update information is temporarily unavailable" }, { status: 503, headers: { "Cache-Control": "no-store" } }); }
}
