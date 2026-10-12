import { deleteBackupParts } from "@/lib/backup-transfer";
import { backupDeviceScope, deviceMayAccessBackup } from "@/lib/backup-access";
import { appDescriptorForType } from "@/lib/app-registry";
import { NextResponse } from "next/server";
import { getStorage, type BackupRecord } from "@/lib/storage";
import { getUserFromRequest } from "@/lib/auth";
import { getDeviceFromRequest } from "@/lib/devices";

export const runtime = "nodejs";
export const maxDuration = 60;

type RouteContext = { params: { id: string } };

function blobKeyFor(id: string): string {
  return `backup-${id}`;
}

async function authorizeBackup(
  req: Request,
  backup: BackupRecord
): Promise<boolean> {
  const deviceAuth = await getDeviceFromRequest(req);
  if (deviceAuth && deviceMayAccessBackup(backupDeviceScope(deviceAuth, await getStorage().readAuthState()), backup)) return true;
  const user = await getUserFromRequest(req);
  return !!(user && user.id === backup.userId);
}

function bytesToB64(buf: Uint8Array): string {
  return Buffer.from(buf).toString("base64");
}

// GET /api/backups/:id → JSON envelope (ciphertext is opaque base64; never decrypted)
export async function GET(req: Request, ctx: RouteContext) {
  const { id } = ctx.params;
  const storage = getStorage();
  const backups = await storage.readCollection<BackupRecord>("backups");
  const backup = backups.find((b) => b.id === id);
  if (!backup || backup.upload) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }
  if (!(await authorizeBackup(req, backup))) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const query=new URL(req.url).searchParams;
  if(query.get("transfer")==="1" && backup.chunks) {
    if(query.has("part")) {
      const raw=query.get("part")!;
      if(query.getAll("part").length!==1 || !/^(0|[1-9][0-9]*)$/.test(raw))return NextResponse.json({error:"Invalid part"},{status:400});
      const part=backup.chunks[Number(raw)];if(!part)return NextResponse.json({error:"Part out of range"},{status:400});
      const bytes=await storage.getBlob(part.key);
      if(!bytes || bytes.length!==part.size)return NextResponse.json({error:"Backup part unavailable"},{status:409});
      return new NextResponse(bytes.slice().buffer as ArrayBuffer,{headers:{"Content-Type":"application/octet-stream","Cache-Control":"no-store"}});
    }
    return NextResponse.json({backupId:id,transport:"chunks-v1",size:backup.size,iv:backup.iv,salt:backup.salt,checksum:backup.checksum,
      parts:backup.chunks.map(part=>({size:part.size,checksum:part.checksum}))},{headers:{"Cache-Control":"no-store"}});
  }
  if(backup.chunks)return NextResponse.json({error:"Update SocialBox to download this chunked backup"},{status:409});
  const blob = await storage.getBlob(blobKeyFor(id));
  if (!blob) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }

  const accept = req.headers.get("accept") ?? "";
  if (accept.includes("application/octet-stream")) {
    const body = blob.slice().buffer as ArrayBuffer;
    return new NextResponse(body, {
      status: 200,
      headers: {
        "Content-Type": "application/octet-stream",
        "Content-Length": String(blob.byteLength),
        "X-SocialBox-AAD": backup.aad ?? "",
        "Cache-Control": "no-store",
      },
    });
  }

  return NextResponse.json({
    backupId: backup.id,
    appType: appDescriptorForType(backup.appType)?.appType ?? null,
    name: backup.name || backup.containerId,
    credentialPolicy: "app-files-only-verify-login",
    id: backup.id,
    containerId: backup.containerId,
    ciphertext: bytesToB64(blob),
    iv: backup.iv,
    salt: backup.salt,
    checksum: backup.checksum,
    createdAt: backup.createdAt,
    attestKeyUsed: backup.attestKeyUsed ?? false,
  }, { headers: { "Cache-Control": "no-store" } });
}

export async function DELETE(req: Request, ctx: RouteContext) {
  const { id } = ctx.params;
  const storage = getStorage();
  const backups = await storage.readCollection<BackupRecord>("backups");
  const backup = backups.find((b) => b.id === id);
  if (!backup || backup.upload) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }
  if (!(await authorizeBackup(req, backup))) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  if(backup.chunks) await deleteBackupParts(backup.chunks, storage);
  else await storage.deleteBlob(blobKeyFor(id));
  await storage.mutateCollection<BackupRecord>("backups", (items) =>
    items.filter((b) => b.id !== id)
  );

  return NextResponse.json({ ok: true });
}
