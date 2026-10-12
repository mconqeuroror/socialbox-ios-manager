import { NextResponse } from "next/server";
import { getStorage, type UserRecord } from "@/lib/storage";
import { verifyPassword, createSessionToken, sessionCookieOptions, SESSION_COOKIE } from "@/lib/auth";
import { ensureAdminSeeded } from "@/lib/admin";
import { findUserByLogin, usernameFromEmail } from "@/lib/identity";

export const runtime = "nodejs";

export async function POST(req: Request) {
  try {
    await ensureAdminSeeded();

    let body: { username?: string; email?: string; password?: string };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const identifier = (body.username || body.email || "").trim();
    const password = body.password;
    if (!identifier || !password) {
      return NextResponse.json({ error: "Username and password are required" }, { status: 400 });
    }

    const storage = getStorage();
    const users = await storage.readCollection<UserRecord>("users");
    const user = findUserByLogin(users, identifier);
    if (!user || !(await verifyPassword(password, user.passwordHash))) {
      return NextResponse.json({ error: "Invalid username or password" }, { status: 401 });
    }

    const sessionUser = {
      id: user.id,
      email: user.email,
      username: user.username || usernameFromEmail(user.email),
      role: user.role,
      licensed: user.licensedAt !== null,
    };

    const token = await createSessionToken(sessionUser);
    const res = NextResponse.json({ token, user: sessionUser });
    const cookie = sessionCookieOptions();
    res.cookies.set(SESSION_COOKIE, token, cookie);
    return res;
  } catch (err) {
    console.error("login error", err);
    return NextResponse.json({ error: "Login failed" }, { status: 500 });
  }
}
