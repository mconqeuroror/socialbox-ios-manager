import { NextResponse } from "next/server";
import { getUserFromRequest } from "@/lib/auth";
import { isConsoleOwner } from "@/lib/console-owner";

export const runtime = "nodejs";

export async function GET(req: Request) {
  const user = await getUserFromRequest(req);
  if (!user) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }
  return NextResponse.json({
    user: {
      email: user.email,
      username: user.username,
      role: user.role,
      consoleOwner: isConsoleOwner(user),
      licensed: user.licensed,
    },
  });
}
