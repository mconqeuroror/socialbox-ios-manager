import { NextResponse } from "next/server";
import { sessionCookieOptions, SESSION_COOKIE } from "@/lib/auth";

export const runtime = "nodejs";

export async function POST() {
  const res = NextResponse.json({ ok: true });
  const opts = sessionCookieOptions(0);
  res.cookies.set(SESSION_COOKIE, "", opts);
  return res;
}
