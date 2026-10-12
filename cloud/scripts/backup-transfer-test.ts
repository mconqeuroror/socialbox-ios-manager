/** Real route integration with isolated storage and synthetic licenses/devices. */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import type { BackupRecord, DeviceRecord, LicenseRecord } from "../src/lib/storage";
async function main() {
  const scratch=await fs.mkdtemp(path.join(os.tmpdir(),"socialbox-transfer-")), previous=process.cwd();
  process.chdir(scratch);delete process.env.BLOB_READ_WRITE_TOKEN;
  process.env.JWT_SECRET="synthetic-cloud-transfer-fixture-secret";
  const {getStorage}=await import("../src/lib/storage");
  const {sha256Hex}=await import("../src/lib/ids");
  const {createSessionToken}=await import("../src/lib/auth");
  const list=await import("../src/app/api/backups/route"), item=await import("../src/app/api/backups/[id]/route");
  const store=getStorage(), now=new Date().toISOString();
  const tokens={a:"a".repeat(64),b:"b".repeat(64),c:"c".repeat(64),foreign:"d".repeat(64)};
  const request=(token:string, body?:object, method=body?"POST":"GET",query="")=>new Request("https://fixture.invalid/api/backups"+query,{method,headers:{Authorization:`Bearer ${token}`,"Content-Type":"application/json"},...(body?{body:JSON.stringify(body)}:{})});
  let count=0;const check=async(name:string,fn:()=>Promise<void>)=>{await fn();count++;console.log("PASS "+name);};
  try {
    await store.writeCollection("users",["owner","foreign"].map(id=>({id,email:id+"@invalid.test",passwordHash:"unused",role:"user",licensedAt:now,createdAt:now})));
    const devices:DeviceRecord[]=Object.entries(tokens).map(([id,token])=>({id,userId:id==="foreign"?"foreign":"owner",name:id,role:"worker",tokenHash:sha256Hex(token),pairedAt:now,lastSeenAt:now,deviceBinding:sha256Hex(id),licenseId:id==="c"?"other-key":"shared-key",licenseStatus:"active"}));
    await store.writeCollection("devices",devices);
    const licenses:LicenseRecord[]=["shared-key","other-key"].map(id=>({id,keyHash:"unused",createdAt:now,activatedBy:"owner@invalid.test",activatedAt:now,kind:"device",ownerUserId:"owner",maxActivations:3,activations:devices.filter(d=>d.userId==="owner"&&d.licenseId===id).map(d=>({deviceId:d.id,deviceBinding:d.deviceBinding!,activatedAt:now,lastCheckedAt:now}))}));
    await store.writeCollection("licenses",licenses);
    await store.writeCollection("profiles",[{id:"pa",profileId:"profile-a",userId:"owner",deviceId:"a",appType:"reddit",nickname:"Research source",lastSeenAt:now}]);
    const blobs:BackupRecord[]=[];
    for (const id of ["one","legacy","foreign"]) {
      const bytes=Buffer.from("synthetic-encrypted-"+id),blobPath=await store.putBlob("backup-"+id,bytes);
      blobs.push({id,deviceId:id==="foreign"?"foreign":"a",userId:id==="foreign"?"foreign":"owner",containerId:"profile-a",createdAt:now,size:bytes.length,iv:Buffer.alloc(12).toString("base64"),salt:Buffer.alloc(16).toString("base64"),checksum:createHash("sha256").update(bytes).digest("hex"),blobPath,...(id!=="legacy"?{licenseId:"shared-key",appType:"reddit"}:{})});
    }
    await store.writeCollection("backups",blobs);
    await check("same license may list and fetch a source phone backup",async()=>{
      const response=await list.GET(request(tokens.b));assert.equal(response.status,200);
      assert.deepEqual((await response.json()).backups.map((b:{id:string})=>b.id),["one"]);
      const restored=await item.GET(request(tokens.b),{params:{id:"one"}});assert.equal(restored.status,200);
      assert.equal((await restored.json()).containerId,"profile-a");
    });
    await check("legacy backups never gain cross-device access by inference",async()=>{
      assert.equal((await item.GET(request(tokens.b),{params:{id:"legacy"}})).status,401);
      assert.equal((await item.GET(request(tokens.a),{params:{id:"legacy"}})).status,200);
    });
    await check("same owner with another license cannot read or delete",async()=>{
      assert.deepEqual((await (await list.GET(request(tokens.c))).json()).backups,[]);
      assert.equal((await item.GET(request(tokens.c),{params:{id:"one"}})).status,401);
      assert.equal((await item.DELETE(request(tokens.c,undefined,"DELETE"),{params:{id:"one"}})).status,401);
    });
    await check("foreign owner cannot use an identically named license",async()=>{
      assert.equal((await item.GET(request(tokens.foreign),{params:{id:"one"}})).status,401);
      assert.equal((await item.GET(request(tokens.b),{params:{id:"foreign"}})).status,401);
    });
    await check("malformed legacy JSON returns a typed error without storage mutation",async()=>{
      const count=(await store.readCollection("backups")).length;
      for(const body of ["null","[]","42"]){
        const req=new Request("https://fixture.invalid/api/backups",{method:"POST",headers:{Authorization:`Bearer ${tokens.a}`,"Content-Type":"application/json"},body});
        assert.equal((await list.POST(req)).status,400);
      }
      assert.equal((await store.readCollection("backups")).length,count);
    });
    await check("upload captures authoritative app, name and license instead of client claims",async()=>{
      const bytes=Buffer.from("new ciphertext");
      const body={containerId:"profile-a",ciphertext:bytes.toString("base64"),iv:Buffer.alloc(12).toString("base64"),salt:Buffer.alloc(16).toString("base64"),checksum:createHash("sha256").update(bytes).digest("hex"),appType:"facebook",licenseId:"other-key",name:"spoofed"};
      const response=await list.POST(request(tokens.a,body));assert.equal(response.status,200);
      const id=(await response.json()).backupId,record=(await store.readCollection<BackupRecord>("backups")).find(b=>b.id===id)!;
      assert.equal(record.licenseId,"shared-key");assert.equal(record.appType,"reddit");assert.equal(record.name,"Research source");
      assert.equal((await item.GET(request(tokens.b),{params:{id}})).status,200);
    });
    await check("app filters reject unknown and ambiguous input",async()=>{
      assert.equal((await list.GET(request(tokens.b,undefined,"GET","?appType=unknown"))).status,400);
      assert.equal((await list.GET(request(tokens.b,undefined,"GET","?appType=reddit&appType=facebook"))).status,400);
      assert.deepEqual((await (await list.GET(request(tokens.b,undefined,"GET","?appType=facebook"))).json()).backups,[]);
    });
    for(const patch of [{revokedAt:now},{expiresAt:"2020-01-01T00:00:00Z"},{deletedAt:now},{expiresAt:"invalid"}])await check("live license denial "+Object.keys(patch)[0],async()=>{
      await store.mutateCollection<LicenseRecord>("licenses",rows=>rows.map(l=>l.id==="shared-key"?{...l,...patch}:l));
      assert.equal((await item.GET(request(tokens.b),{params:{id:"one"}})).status,401);
      assert.equal((await item.DELETE(request(tokens.a,undefined,"DELETE"),{params:{id:"one"}})).status,401);
      await store.writeCollection("licenses",licenses);
    });
    await check("activation binding mismatch fails even if status says active",async()=>{
      await store.mutateCollection<DeviceRecord>("devices",rows=>rows.map(d=>d.id==="b"?{...d,deviceBinding:"wrong"}:d));
      assert.equal((await item.GET(request(tokens.b),{params:{id:"one"}})).status,401);
      await store.writeCollection("devices",devices);
    });
    await check("existing owner web session sees metadata and deletes own backups",async()=>{
      const jwt=await createSessionToken({id:"owner",email:"owner@invalid.test",username:"owner",role:"user",licensed:true});
      const response=await list.GET(request(jwt));assert.equal(response.headers.get("cache-control"),"no-store");
      const rows=(await response.json()).backups;assert(rows.some((b:{id:string})=>b.id==="one"));assert(!rows.some((b:{id:string})=>b.id==="foreign"));
      assert.equal((await item.DELETE(request(jwt,undefined,"DELETE"),{params:{id:"legacy"}})).status,200);
    });
    await check("authorized target can delete shared backup without touching other blobs",async()=>{
      assert.equal((await item.DELETE(request(tokens.b,undefined,"DELETE"),{params:{id:"one"}})).status,200);
      assert.equal(await store.getBlob("backup-one"),null);assert(await store.getBlob("backup-foreign"));
    });
    console.log(`${count} licensed transfer route groups passed`);
  } finally {process.chdir(previous);await fs.rm(scratch,{recursive:true,force:true});}
}
main().catch(error=>{console.error(error);process.exitCode=1;});
