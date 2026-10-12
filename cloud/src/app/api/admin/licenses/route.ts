import { NextResponse } from "next/server";
import { getStorage, type LicenseRecord } from "@/lib/storage";
import { getConsoleOwnerFromRequest } from "@/lib/console-auth";
import { ConsoleOwnerRequiredError, requireCurrentConsoleOwner } from "@/lib/console-owner";
import { generateLicenseKey, nowIso, randomId, sha256Hex } from "@/lib/ids";
import { licenseValidity } from "@/lib/licenses";
import { keyIdPrefix, listLicenseAudit, publicAuditRow } from "@/lib/audit";
import { deviceLicenseStatus } from "@/lib/device-licenses";

export const runtime = "nodejs";

// GET /api/admin/licenses → list (no keys) + recent audit
export async function GET(req: Request) {
  const user = await getConsoleOwnerFromRequest(req);
  if (!user) {
    return NextResponse.json({ error: "Owner access required" }, { status: 403 });
  }
  const storage = getStorage();
  // Audit is a separate collection. Finish that read before observing the
  // final auth snapshot, so waiting for it cannot retain stale owner authority.
  const audit = await listLicenseAudit(100);
  const state = await storage.readAuthState();
  try {
    requireCurrentConsoleOwner(state.users, user.id);
  } catch (error) {
    if (error instanceof ConsoleOwnerRequiredError)
      return NextResponse.json({ error: "Owner access required" }, { status: 403 });
    throw error;
  }
  const licenses = state.licenses;
  const sorted = [...licenses].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  return NextResponse.json({
    licenses: sorted.map((l) => {
      const status = licenseValidity(l);
      return {
        id: l.id,
        createdAt: l.createdAt,
        activatedBy: l.activatedBy,
        activatedAt: l.activatedAt,
        revokedAt: l.revokedAt ?? null,
        expiresAt: l.expiresAt ?? null,
        lastValidatedAt: l.lastValidatedAt ?? null,
        valid: status.valid,
        revoked: status.revoked,
        keyIdPrefix: keyIdPrefix(l.id),
        kind: l.kind ?? "legacy-account",
        status: l.deletedAt ? "deleted" : deviceLicenseStatus(l),
        ownerUserId: l.ownerUserId ?? null,
        owner: state.users.find((user) => user.id === l.ownerUserId)?.email ?? l.activatedBy ?? null,
        maxActivations: l.maxActivations ?? 1,
        label: l.label ?? "", note: l.note ?? "", deletedAt: l.deletedAt ?? null,
        activations: (l.activations ?? []).map((activation) => ({ ...activation,
          deviceName: state.devices.find((device) => device.id === activation.deviceId)?.name ?? "Missing device" })),
        history: state.deviceLicensing!.events.filter((event) => event.licenseId === l.id),
      };
    }),
    audit: audit.map(publicAuditRow),
    migration: { migratedAt: state.deviceLicensing!.migratedAt,
      adminDevices: state.deviceLicensing!.adminDevices.map((entry) => ({ ...entry,
        name: state.devices.find((device) => device.id === entry.deviceId)?.name ?? "Missing device" })) },
  });
}

// Newly issued device keys have no customer-term expiry and exactly one activation.
export async function POST(req: Request) {
  const user = await getConsoleOwnerFromRequest(req);
  if (!user) {
    return NextResponse.json({ error: "Owner access required" }, { status: 403 });
  }

  let body: { count?: number; expiresAt?: unknown; expiresInDays?: unknown; maxActivations?: unknown;
    ownerUserId?: string; label?: string; note?: string };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }
  if (!body || typeof body !== "object" || Array.isArray(body))
    return NextResponse.json({ error: "Expected a JSON object" }, { status: 400 });

  const count = Number(body.count ?? 1);
  if (!Number.isInteger(count) || count < 1 || count > 100) {
    return NextResponse.json({ error: "count must be an integer between 1 and 100" }, { status: 400 });
  }
  if (body.maxActivations !== undefined && body.maxActivations !== 1)
    return NextResponse.json({ error: "New device keys activate on exactly one device" }, { status: 400 });
  if ((body.expiresAt !== undefined && body.expiresAt !== null) || body.expiresInDays !== undefined)
    return NextResponse.json({ error: "New device keys have no expiry; omit expiry fields" }, { status: 400 });
  if ((body.label !== undefined && (typeof body.label !== "string" || Array.from(body.label).length > 80)) ||
      (body.note !== undefined && (typeof body.note !== "string" || Array.from(body.note).length > 200)) ||
      (body.ownerUserId !== undefined && (typeof body.ownerUserId !== "string" || !body.ownerUserId)))
    return NextResponse.json({ error: "label must be ≤80 characters, note ≤200, and ownerUserId an existing user" }, { status: 400 });
  const ownerUserId = body.ownerUserId ?? user.id;

  const { default: bcrypt } = await import("bcryptjs");
  const storage = getStorage();

  const newLicenses: LicenseRecord[] = [];
  const keys: string[] = [];
  for (let i = 0; i < count; i++) {
    const key = generateLicenseKey();
    keys.push(key);
    newLicenses.push({
      id: randomId(8),
      keyHash: await bcrypt.hash(key, 10),
      keyFingerprint: sha256Hex(key),
      createdAt: nowIso(),
      activatedBy: null,
      activatedAt: null,
      revokedAt: null,
      expiresAt: null,
      kind: "device", ownerUserId, maxActivations: 1, label: body.label ?? "", note: body.note ?? "", activations: [],
    });
  }

  const missingOwner = new Error("OWNER_NOT_FOUND");
  try {
    await storage.mutateAuthState((state) => {
      requireCurrentConsoleOwner(state.users, user.id);
      if (!state.users.some((entry) => entry.id === ownerUserId)) throw missingOwner;
      if (newLicenses.some((entry) => state.licenses.some((old) => old.id === entry.id || old.keyFingerprint === entry.keyFingerprint)))
        throw new Error("License collision; generation must be retried");
      state.licenses.push(...newLicenses);
      state.deviceLicensing!.events.push(...newLicenses.map((entry) => ({ id: randomId(12), at: nowIso(),
        action: "generate", licenseId: entry.id, actorUserId: user.id })));
      return state;
    });
  } catch (error) {
    if (error instanceof ConsoleOwnerRequiredError)
      return NextResponse.json({ error: error.message }, { status: 403 });
    if (error === missingOwner) return NextResponse.json({ error: "License owner not found" }, { status: 404 });
    throw error;
  }

  return NextResponse.json({
    licenses: keys.map((key, i) => ({
      key,
      id: newLicenses[i].id,
      expiresAt: newLicenses[i].expiresAt ?? null,
    })),
  });
}
