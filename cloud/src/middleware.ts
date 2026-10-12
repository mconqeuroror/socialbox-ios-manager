import { NextResponse, type NextRequest } from "next/server";
import { jwtVerify } from "jose";
import { isConsoleOwner } from "./lib/console-owner";
// Retained cookie keeps the owner's existing session; server layout/APIs re-read storage.
const SESSION_COOKIE = "socialbox_session";
export async function middleware(req: NextRequest) {
  const path = req.nextUrl.pathname;
  // Login must remain reachable even when a signed session has been revoked.
  if (path === "/login") return NextResponse.next();
  if (path === "/install") {
    const response = NextResponse.next();
    response.headers.set("Cache-Control", "no-store");
    return response;
  }
  const token = req.cookies.get(SESSION_COOKIE)?.value;
  const secret = process.env.JWT_SECRET || process.env.AUTH_SECRET || "";
  let owner = false;
  if (token && secret.length >= 16) try {
    const { payload } = await jwtVerify(token, new TextEncoder().encode(secret));
    owner = typeof payload.sub === "string" && isConsoleOwner({ email: payload.email, role: payload.role });
  } catch { /* denied */ }
  if (!owner) return NextResponse.redirect(new URL("/login", req.url));
  // Browser console is license-only for now. Machine update, license and APT routes
  // are deliberately outside this matcher and retain their existing API contracts.
  if (path !== "/admin") return NextResponse.redirect(new URL("/admin", req.url));
  const response = NextResponse.next();
  response.headers.set("Cache-Control", "private, no-store");
  return response;
}
export const config = { matcher: ["/", "/login", "/admin/:path*", "/apps/:path*", "/install", "/updates"] };
