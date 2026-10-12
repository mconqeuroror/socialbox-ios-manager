import { NextResponse } from "next/server";
import { getStorage, type UserRecord } from "@/lib/storage";
import { verifyPassword, createSessionToken, sessionCookieOptions, SESSION_COOKIE } from "@/lib/auth";
import { ensureAdminSeeded } from "@/lib/admin";
import { isConsoleOwner } from "@/lib/console-owner";
import { findUserByLogin, usernameFromEmail } from "@/lib/identity";
export const runtime = "nodejs";
const json = (body: unknown, status: number) => NextResponse.json(body, { status, headers: { "Cache-Control": "private, no-store" } });

/** Browser-only entry. Customer login/registration and device activation stay intact. */
export async function POST(req: Request) {
  if (req.headers.get("origin") !== new URL(req.url).origin ||
      !req.headers.get("content-type")?.startsWith("application/json"))
    return json({ error: "A same-origin sign-in is required" }, 403);
  let body: unknown;
  try { const raw = await req.text(); if (raw.length > 4096) throw new Error(); body = JSON.parse(raw); }
  catch { return json({ error: "Invalid sign-in request" }, 400); }
  if (!body || typeof body !== "object" || Array.isArray(body)) return json({ error: "Invalid sign-in request" }, 400);
  const input = body as Record<string, unknown>;
  if (typeof input.username !== "string" || !input.username.trim() ||
      typeof input.password !== "string" || !input.password || input.password.length > 1024)
    return json({ error: "Username and password are required" }, 400);
  try {
    await ensureAdminSeeded();
    const users = await getStorage().readCollection<UserRecord>("users");
    const user = findUserByLogin(users.filter(isConsoleOwner), input.username);
    if (!user || !await verifyPassword(input.password, user.passwordHash))
      return json({ error: "Invalid username or password" }, 401);
    const sessionUser = { id: user.id, email: user.email, username: user.username || usernameFromEmail(user.email),
      role: user.role, licensed: user.licensedAt !== null };
    const token = await createSessionToken(sessionUser);
    const response = json({ user: { ...sessionUser, consoleOwner: true } }, 200);
    response.cookies.set(SESSION_COOKIE, token, sessionCookieOptions());
    return response;
  } catch {
    return json({ error: "Sign-in is temporarily unavailable. Try again." }, 503);
  }
}
