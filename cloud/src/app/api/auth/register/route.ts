import { NextResponse } from "next/server";
import { getStorage, type UserRecord } from "@/lib/storage";
import { hashPassword, createSessionToken, sessionCookieOptions, SESSION_COOKIE } from "@/lib/auth";
import { ensureAdminSeeded } from "@/lib/admin";
import { usernameFromEmail } from "@/lib/identity";
import { nowIso, randomId } from "@/lib/ids";

export const runtime = "nodejs";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export async function POST(req: Request) {
  try {
    await ensureAdminSeeded();

    let body: { email?: string; password?: string };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const email = body.email?.toLowerCase().trim();
    const password = body.password;
    if (!email || !password) {
      return NextResponse.json({ error: "Email and password are required" }, { status: 400 });
    }
    if (!EMAIL_RE.test(email)) {
      return NextResponse.json({ error: "Invalid email address" }, { status: 400 });
    }
    if (password.length < 8) {
      return NextResponse.json({ error: "Password must be at least 8 characters" }, { status: 400 });
    }

    const storage = getStorage();
    const users = await storage.readCollection<UserRecord>("users");
    if (users.some((u) => u.email === email)) {
      return NextResponse.json({ error: "An account with this email already exists" }, { status: 409 });
    }

    const user: UserRecord = {
      id: randomId(8),
      email,
      username: usernameFromEmail(email),
      passwordHash: await hashPassword(password),
      role: "user",
      licensedAt: null,
      createdAt: nowIso(),
    };
    await storage.mutateCollection<UserRecord>("users", (items) => [...items, user]);

    const sessionUser = {
      id: user.id,
      email: user.email,
      username: user.username || usernameFromEmail(user.email),
      role: user.role,
      licensed: false,
    };
    const token = await createSessionToken(sessionUser);
    const res = NextResponse.json({ token, user: sessionUser });
    const cookie = sessionCookieOptions();
    res.cookies.set(SESSION_COOKIE, token, cookie);
    return res;
  } catch (err) {
    console.error("register error", err);
    return NextResponse.json({ error: "Registration failed" }, { status: 500 });
  }
}
