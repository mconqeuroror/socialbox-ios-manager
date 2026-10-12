import { NextResponse } from "next/server";
import { getStorage } from "@/lib/storage";
import { getConsoleOwnerFromRequest } from "@/lib/console-auth";
import { ConsoleOwnerRequiredError, requireCurrentConsoleOwner } from "@/lib/console-owner";

export const runtime = "nodejs";

export async function GET(req: Request) {
  const user = await getConsoleOwnerFromRequest(req);
  if (!user) {
    return NextResponse.json({ error: "Owner access required" }, { status: 403 });
  }
  const storage = getStorage();
  const state = await storage.readAuthState();
  try {
    requireCurrentConsoleOwner(state.users, user.id);
  } catch (error) {
    if (error instanceof ConsoleOwnerRequiredError)
      return NextResponse.json({ error: "Owner access required" }, { status: 403 });
    throw error;
  }
  const { users, devices } = state;
  const deviceCounts = new Map<string, number>();
  for (const d of devices) {
    deviceCounts.set(d.userId, (deviceCounts.get(d.userId) ?? 0) + 1);
  }
  const sorted = [...users].sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  return NextResponse.json({
    users: sorted.map((u) => ({
      id: u.id,
      email: u.email,
      role: u.role,
      licensed: u.licensedAt !== null,
      createdAt: u.createdAt,
      deviceCount: deviceCounts.get(u.id) ?? 0,
    })),
  });
}
