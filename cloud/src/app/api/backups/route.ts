import { backupDeviceScope, deviceMayAccessBackup } from "@/lib/backup-access";
import { appDescriptorForType, requestedAppFilter } from "@/lib/app-registry";
import { isCanonicalProfileId } from "@/lib/profile-inventory";
import { createHash } from "node:crypto";
import { NextResponse } from "next/server";
import { getStorage, type BackupRecord, type DeviceRecord } from "@/lib/storage";
import { getUserFromRequest } from "@/lib/auth";
import { getDeviceFromRequest } from "@/lib/devices";
import { nowIso, randomId } from "@/lib/ids";

export const runtime = "nodejs";
export const maxDuration = 60;

const MAX_BLOB_BYTES = 200 * 1024 * 1024; // 200 MB
const B64_RE = /^[A-Za-z0-9+/]+=*$/;

function sha256Hex(buf: Uint8Array): string {
  return createHash("sha256").update(buf).digest("hex");
}

function b64ToBytes(value: string): Uint8Array | null {
  try {
    const cleaned = value.replace(/\s+/g, "");
    if (!cleaned || !B64_RE.test(cleaned)) return null;
    return new Uint8Array(Buffer.from(cleaned, "base64"));
  } catch {
    return null;
  }
}

function bytesToB64(buf: Uint8Array): string {
  return Buffer.from(buf).toString("base64");
}

// POST /api/backups
// Specified contract: JSON {containerId, ciphertext, iv, salt, checksum, createdAt, attestKeyUsed?}
// Legacy fallback: raw octet-stream + X-SocialBox-* headers (stored as opaque ciphertext).
export async function POST(req: Request) {
  const deviceAuth = await getDeviceFromRequest(req);
  if (!deviceAuth) {
    return NextResponse.json({ error: "Device authentication required" }, { status: 401 });
  }

  const storage = getStorage();
  const scope = backupDeviceScope(deviceAuth, await storage.readAuthState());
  if (!scope) return NextResponse.json({ error: "Current device license required" }, { status: 401 });
  const contentType = req.headers.get("content-type") ?? "";

  let containerId: string;
  let iv: string;
  let salt: string;
  let checksum: string;
  let createdAt: string;
  let attestKeyUsed: boolean | undefined;
  let size: number;
  let blobBytes: Uint8Array;
  let aad: string | undefined;

  if (contentType.includes("application/json")) {
    let body: {
      containerId?: string;
      ciphertext?: string;
      iv?: string;
      salt?: string;
      checksum?: string;
      createdAt?: string;
      attestKeyUsed?: boolean;
    };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    if (!body || typeof body !== "object" || Array.isArray(body)) return NextResponse.json({ error: "JSON object required" }, { status: 400 });
    containerId = typeof body.containerId === "string" ? body.containerId : "";
    if (!isCanonicalProfileId(containerId)) {
      return NextResponse.json({ error: "containerId is required (max 128 chars)" }, { status: 400 });
    }
    if (typeof body.ciphertext !== "string" || typeof body.iv !== "string" || typeof body.salt !== "string" || typeof body.checksum !== "string" || !body.ciphertext || !body.iv || !body.salt || !body.checksum) {
      return NextResponse.json(
        { error: "ciphertext, iv, salt, and checksum are required" },
        { status: 400 }
      );
    }

    const ct = b64ToBytes(body.ciphertext);
    const ivBytes = b64ToBytes(body.iv);
    const saltBytes = b64ToBytes(body.salt);
    if (!ct || ct.byteLength === 0) {
      return NextResponse.json({ error: "ciphertext must be base64" }, { status: 400 });
    }
    if (!ivBytes || ivBytes.byteLength !== 12) {
      return NextResponse.json({ error: "iv must be 12-byte nonce, base64" }, { status: 400 });
    }
    if (!saltBytes || saltBytes.byteLength !== 16) {
      return NextResponse.json({ error: "salt must be 16-byte salt, base64" }, { status: 400 });
    }
    if (ct.byteLength > MAX_BLOB_BYTES) {
      return NextResponse.json(
        { error: `Blob too large (max ${MAX_BLOB_BYTES} bytes)` },
        { status: 413 }
      );
    }

    const expected = sha256Hex(ct);
    if (body.checksum.toLowerCase() !== expected) {
      return NextResponse.json({ error: "checksum mismatch" }, { status: 400 });
    }

    iv = bytesToB64(ivBytes);
    salt = bytesToB64(saltBytes);
    checksum = expected;
    createdAt = typeof body.createdAt === "string" && body.createdAt.length > 0 ? body.createdAt : nowIso();
    attestKeyUsed = typeof body.attestKeyUsed === "boolean" ? body.attestKeyUsed : undefined;
    size = ct.byteLength;
    blobBytes = ct;
  } else {
    // Legacy raw-blob path (device builds that still send octet-stream).
    containerId = req.headers.get("x-socialbox-container") ?? "";
    const aadHeader = req.headers.get("x-socialbox-aad");
    if (!isCanonicalProfileId(containerId)) {
      return NextResponse.json({ error: "X-SocialBox-Container header is required" }, { status: 400 });
    }
    if (containerId.length > 128) {
      return NextResponse.json({ error: "X-SocialBox-Container too long" }, { status: 400 });
    }
    blobBytes = new Uint8Array(await req.arrayBuffer());
    if (blobBytes.byteLength === 0) {
      return NextResponse.json({ error: "Empty blob" }, { status: 400 });
    }
    if (blobBytes.byteLength > MAX_BLOB_BYTES) {
      return NextResponse.json(
        { error: `Blob too large (max ${MAX_BLOB_BYTES} bytes)` },
        { status: 413 }
      );
    }
    iv = "";
    salt = "";
    checksum = sha256Hex(blobBytes);
    createdAt = nowIso();
    size = blobBytes.byteLength;
    if (aadHeader) {
      try {
        aad = JSON.stringify(JSON.parse(aadHeader));
      } catch {
        return NextResponse.json({ error: "X-SocialBox-AAD must be valid JSON" }, { status: 400 });
      }
    }
  }

  const inventory = await storage.readInventoryState();
  const profile = inventory.profiles.find((profile) => profile.profileId === containerId &&
      profile.userId === deviceAuth.userId && profile.deviceId === deviceAuth.device.id);
  if (!profile)
    return NextResponse.json({ error: "Register this profile on the authenticated device before uploading a backup" }, { status: 403 });
  const app = appDescriptorForType(profile.appType);
  if (!app) return NextResponse.json({ error: "Unknown profile app type" }, { status: 409 });
  const id = randomId(8);
  const blobKey = `backup-${id}`;
  const blobPath = await storage.putBlob(blobKey, blobBytes);

  const record: BackupRecord = {
    id,
    licenseId: scope.licenseId,
    appType: app.appType,
    name: typeof profile.nickname === "string" && profile.nickname.trim() ? profile.nickname.trim().slice(0,128) : containerId,
    deviceId: deviceAuth.device.id,
    userId: deviceAuth.userId,
    containerId,
    size,
    createdAt,
    iv,
    salt,
    checksum,
    attestKeyUsed,
    aad,
    blobPath,
  };
  await storage.mutateCollection<BackupRecord>("backups", (items) => [...items, record]);

  // Specified contract: {backupId}. Also echo id/createdAt for older clients.
  return NextResponse.json({ backupId: id, id, createdAt });
}

// GET /api/backups?containerId=
export async function GET(req: Request) {
  const user = await getUserFromRequest(req);
  const device = user ? null : await getDeviceFromRequest(req);
  const userId = user?.id ?? device?.userId;
  if (!userId) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  let appFilter: string | undefined;
  try { appFilter = requestedAppFilter(req, !!device); }
  catch { return NextResponse.json({ error: "Unknown or ambiguous appType" }, { status: 400 }); }
  const url = new URL(req.url);
  const containerFilter = url.searchParams.get("containerId") ?? "";

  const storage = getStorage();
  const scope = device ? backupDeviceScope(device, await storage.readAuthState()) : null;
  if (device && !scope) return NextResponse.json({ error: "Current device license required" }, { status: 401 });
  const backups = await storage.readCollection<BackupRecord>("backups");
  const devices = await storage.readCollection<DeviceRecord>("devices");
  const deviceNames = new Map<string, string>(devices.map((d) => [d.id, d.name]));

  const owned = backups
    .filter((b) => !b.upload && b.userId === userId && (!device || deviceMayAccessBackup(scope,b)))
    .filter((b) => { const app = appDescriptorForType(b.appType); return app && (!appFilter || app.appType === appFilter); })
    .filter((b) => !containerFilter || b.containerId === containerFilter)
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
    .map((b) => ({
      backupId: b.id,
      appType: appDescriptorForType(b.appType)!.appType,
      name: b.name || b.containerId,
      transferScope: b.licenseId ? "same-license" : "origin-device",
      credentialPolicy: "app-files-only-verify-login",
      id: b.id,
      containerId: b.containerId,
      createdAt: b.createdAt,
      checksum: b.checksum,
      attestKeyUsed: b.attestKeyUsed ?? false,
      deviceId: b.deviceId,
      deviceName: deviceNames.get(b.deviceId) ?? "Unknown device",
      size: b.size,
      aad: b.aad,
    }));

  return NextResponse.json({ backups: owned }, { headers: { "Cache-Control": "no-store" } });
}
