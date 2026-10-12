import { SignJWT, jwtVerify } from "jose";
import bcrypt from "bcryptjs";
import { getStorage, type Role } from "./storage";
import { usernameFromEmail } from "./identity";

export const SESSION_COOKIE = "socialbox_session";
const SESSION_TTL_SECONDS = 7 * 24 * 60 * 60; // 7 days

export interface SessionUser {
  id: string;
  email: string;
  username: string;
  role: Role;
  licensed: boolean;
}

function getSecret(): Uint8Array {
  const secret = process.env.JWT_SECRET || process.env.AUTH_SECRET;
  if (!secret || secret.length < 16) {
    throw new Error("JWT_SECRET or AUTH_SECRET env var must be set (at least 16 characters)");
  }
  return new TextEncoder().encode(secret);
}

export function hashPassword(password: string): Promise<string> {
  return bcrypt.hash(password, 10);
}

export function verifyPassword(password: string, hash: string): Promise<boolean> {
  return bcrypt.compare(password, hash);
}

export async function createSessionToken(user: SessionUser): Promise<string> {
  return new SignJWT({ sub: user.id, email: user.email, username: user.username, role: user.role })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime(`${SESSION_TTL_SECONDS}s`)
    .sign(getSecret());
}

export async function verifySessionToken(token: string): Promise<SessionUser | null> {
  try {
    const { payload } = await jwtVerify(token, getSecret());
    if (typeof payload.sub !== "string") return null;
    // Session payload is a cache; re-read user from storage so revocations /
    // license activations are reflected immediately.
    const storage = getStorage();
    const users = await storage.readCollection<import("./storage").UserRecord>("users");
    const user = users.find((u) => u.id === payload.sub);
    if (!user) return null;
    return {
      id: user.id,
      email: user.email,
      username: user.username || usernameFromEmail(user.email),
      role: user.role,
      licensed: user.licensedAt !== null,
    };
  } catch {
    return null;
  }
}

export function sessionCookieOptions(maxAge: number = SESSION_TTL_SECONDS) {
  return {
    name: SESSION_COOKIE,
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax" as const,
    path: "/",
    maxAge,
  };
}

export async function getUserFromRequest(req: Request): Promise<SessionUser | null> {
  const auth = req.headers.get("authorization");
  if (auth?.startsWith("Bearer ")) {
    const bearer = auth.slice("Bearer ".length).trim();
    // Device tokens are 64 hex (no dots). User JWTs are three base64 segments.
    if (bearer.includes(".")) {
      const user = await verifySessionToken(bearer);
      if (user) return user;
    }
  }

  const cookieHeader = req.headers.get("cookie") ?? "";
  const cookies = cookieHeader.split(";").map((c) => c.trim());
  const sessionCookie = cookies.find((c) => c.startsWith(`${SESSION_COOKIE}=`));
  if (!sessionCookie) return null;
  const token = sessionCookie.slice(SESSION_COOKIE.length + 1);
  if (!token) return null;
  return verifySessionToken(token);
}
