import { createHash } from "node:crypto";
import { NextResponse } from "next/server";
import { getStorage, type BackupRecord } from "@/lib/storage";
import { getDeviceFromRequest } from "@/lib/devices";
import { backupDeviceScope } from "@/lib/backup-access";
import { appDescriptorForType } from "@/lib/app-registry";
import { isCanonicalProfileId } from "@/lib/profile-inventory";
import { nowIso, randomId } from "@/lib/ids";
import { BACKUP_PART_BYTES, BACKUP_MAX_BYTES, backupPartSize, deleteBackupParts } from "@/lib/backup-transfer";
export const runtime = "nodejs";
export const maxDuration = 60;
const json = (value: object, status = 200) => NextResponse.json(value, { status, headers: { "Cache-Control": "no-store" } });
const hex = (value: unknown): value is string => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const nonce = (value: unknown, size: number): value is string => typeof value === "string" && Buffer.from(value,"base64").length===size && Buffer.from(value,"base64").toString("base64")===value;
async function authentication(req: Request) {
  const auth = await getDeviceFromRequest(req);
  const scope = auth && backupDeviceScope(auth, await getStorage().readAuthState());
  return auth && scope ? { auth, scope } : null;
}
function ownsUpload(record: BackupRecord, identity: NonNullable<Awaited<ReturnType<typeof authentication>>>) {
  return record.deviceId===identity.scope.deviceId && record.userId===identity.scope.userId &&
    record.licenseId===identity.scope.licenseId && record.upload?.tokenHash===identity.auth.device.tokenHash &&
    record.upload.expiresAt>Date.now();
}
// Start with all expected chunk hashes. This bounds storage and allows cleanup
// even when a part was stored but its acknowledgement never reached the client.
export async function POST(req: Request) {
  const identity=await authentication(req); if(!identity) return json({error:"Current device license required"},401);
  if(Number(req.headers.get("content-length"))>65536) return json({error:"Transfer metadata too large"},413);
  const text=await req.text(); if(text.length>65536) return json({error:"Transfer metadata too large"},413);
  let body; try { body=JSON.parse(text); } catch { return json({error:"Invalid JSON"},400); }
  if(!body || typeof body!=="object" || Array.isArray(body)) return json({error:"Invalid transfer metadata"},400);
  const store=getStorage();
  if(body.complete) {
    if(typeof body.complete!=="string") return json({error:"Invalid upload ID"},400);
    let complete=false;
    await store.mutateCollection<BackupRecord>("backups",rows=>{complete=false;return rows.map(record=>{
      if(record.id!==body.complete) return record;
      // A lost success receipt can be retried by its original, still-authorized phone.
      if(!record.upload) { complete=record.deviceId===identity.scope.deviceId && record.userId===identity.scope.userId && record.licenseId===identity.scope.licenseId;return record; }
      if(!ownsUpload(record,identity) || record.upload.received.length!==record.chunks?.length) return record;
      complete=true; const {upload,...published}=record; return published;
    });});
    return complete?json({backupId:body.complete}):json({error:"Upload is incomplete, expired or unavailable"},409);
  }
  if(!isCanonicalProfileId(body.containerId) || !Number.isSafeInteger(body.size) || body.size<16 || body.size>BACKUP_MAX_BYTES ||
     !hex(body.checksum) || !nonce(body.iv,12) || !nonce(body.salt,16) || !Array.isArray(body.parts) ||
     body.parts.length!==Math.ceil(body.size/BACKUP_PART_BYTES) || !body.parts.every(hex)) return json({error:"Invalid encrypted transfer metadata"},400);
  const profile=(await store.readInventoryState()).profiles.find(p=>p.profileId===body.containerId && p.deviceId===identity.scope.deviceId && p.userId===identity.scope.userId);
  const app=profile && appDescriptorForType(profile.appType);
  if(!profile || !app) return json({error:"Register this profile on the authenticated device first"},403);
  // Expired sessions have a two-minute grace beyond expiry (function max 60 s).
  // Cleanup never selects completed backups or another phone's staged objects.
  const expired=(await store.readCollection<BackupRecord>("backups")).filter(b=>b.deviceId===identity.scope.deviceId && b.userId===identity.scope.userId && b.upload && b.upload.expiresAt<Date.now()-120000);
  for(const record of expired) {
    await deleteBackupParts(record.chunks ?? [], store);
    await store.mutateCollection<BackupRecord>("backups",rows=>rows.filter(b=>b.id!==record.id || !b.upload));
  }
  const id=randomId(16);
  const record:BackupRecord={id,deviceId:identity.scope.deviceId,userId:identity.scope.userId,licenseId:identity.scope.licenseId,
    appType:app.appType,name:profile.nickname?.trim().slice(0,128)||body.containerId,containerId:body.containerId,
    size:body.size,createdAt:nowIso(),iv:body.iv,salt:body.salt,checksum:body.checksum,attestKeyUsed:body.attestKeyUsed===true,blobPath:"chunked-v1",
    chunks:body.parts.map((checksum:string,index:number)=>({key:`backup-${id}-${index}-${checksum}`,checksum,size:backupPartSize(body.size,index)})),
    upload:{expiresAt:Date.now()+3600000,tokenHash:identity.auth.device.tokenHash!,received:[]}};
  let accepted=false;
  await store.mutateCollection<BackupRecord>("backups",rows=>{
    accepted=false;
    if(rows.filter(b=>b.deviceId===record.deviceId && b.userId===record.userId && b.upload).length>=4)return rows;
    accepted=true;return [...rows,record];
  });
  return accepted?json({uploadId:id,partBytes:BACKUP_PART_BYTES}):json({error:"Too many unfinished uploads. Wait for expired transfers to be cleaned up (about one hour)."},409);
}
export async function PUT(req: Request) {
  const identity=await authentication(req); if(!identity)return json({error:"Current device license required"},401);
  const query=new URL(req.url).searchParams,id=query.get("id"),raw=query.get("part");
  if(query.getAll("id").length!==1 || query.getAll("part").length!==1 || !raw || !/^(0|[1-9][0-9]*)$/.test(raw))return json({error:"Invalid part"},400);
  const index=Number(raw),store=getStorage(),record=(await store.readCollection<BackupRecord>("backups")).find(b=>b.id===id);
  if(!record || !ownsUpload(record,identity))return json({error:"Upload unavailable"},401);
  const part=record.chunks?.[index];if(!part)return json({error:"Part out of range"},400);
  if(Number(req.headers.get("content-length"))>BACKUP_PART_BYTES)return json({error:"Part too large"},413);
  const bytes=new Uint8Array(await req.arrayBuffer());
  if(bytes.length!==part.size || createHash("sha256").update(bytes).digest("hex")!==part.checksum)return json({error:"Part length or checksum mismatch"},400);
  await store.putBlob(part.key,bytes);
  let recorded=false;
  await store.mutateCollection<BackupRecord>("backups",rows=>rows.map(current=>{
    if(current.id!==id || !ownsUpload(current,identity))return current;
    recorded=true;return {...current,upload:{...current.upload!,received:[...new Set([...current.upload!.received,index])]}};
  }));
  return recorded?json({ok:true}):json({error:"Upload expired before acknowledgement"},409);
}
