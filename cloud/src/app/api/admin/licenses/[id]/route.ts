import { NextResponse } from "next/server";
import { getConsoleOwnerFromRequest } from "@/lib/console-auth";
import { manageDeviceLicense } from "@/lib/device-licenses";
export const runtime = "nodejs";

export async function PATCH(req: Request, { params }: { params: { id: string } }) {
  const user = await getConsoleOwnerFromRequest(req);
  if (!user) return NextResponse.json({ error: "Owner access required" }, { status: 403 });
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return NextResponse.json({ error: "Invalid JSON" }, { status: 400 }); }
  if (!body || typeof body !== "object" || Array.isArray(body) ||
      Object.keys(body).some((key) => !["action", "label", "note", "ownerUserId"].includes(key)) ||
      (body.action !== undefined && !["enable", "delete"].includes(String(body.action))) ||
      (body.label !== undefined && (typeof body.label !== "string" || Array.from(body.label).length > 80)) ||
      (body.note !== undefined && (typeof body.note !== "string" || Array.from(body.note).length > 200)) ||
      (body.ownerUserId !== undefined && (typeof body.ownerUserId !== "string" || !body.ownerUserId)))
    return NextResponse.json({ error: "Expected action enable/delete, label ≤80, note ≤200, or an existing ownerUserId" }, { status: 400 });
  const result = await manageDeviceLicense(params.id, user.id, body);
  return NextResponse.json(result.body, { status: result.status });
}
export async function DELETE(req: Request, context: { params: { id: string } }) {
  const user = await getConsoleOwnerFromRequest(req);
  if (!user) return NextResponse.json({ error: "Owner access required" }, { status: 403 });
  const result = await manageDeviceLicense(context.params.id, user.id, { action: "delete" });
  return NextResponse.json(result.body, { status: result.status });
}
