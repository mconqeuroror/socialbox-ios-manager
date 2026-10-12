/** Actual route transport with isolated data and no external requests. */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {createHash} from "node:crypto";
import type {BackupRecord} from "../src/lib/storage";
async function main(){
 const tmp=await fs.mkdtemp(path.join(os.tmpdir(),"socialbox-chunks-")),cwd=process.cwd();process.chdir(tmp);delete process.env.BLOB_READ_WRITE_TOKEN;
 const {getStorage}=await import("../src/lib/storage"),{sha256Hex}=await import("../src/lib/ids");
 const transfer=await import("../src/app/api/backups/transfer/route"),list=await import("../src/app/api/backups/route"),item=await import("../src/app/api/backups/[id]/route");
 const store=getStorage(),now=new Date().toISOString(),token="a".repeat(64),foreign="b".repeat(64),chunk=1024*1024;
 const hash=(b:Uint8Array)=>createHash("sha256").update(b).digest("hex");
 const req=(method:string,body?:unknown,query="",auth=token)=>new Request("https://fixture.invalid/api/backups/transfer"+query,{method,headers:{Authorization:"Bearer "+auth},...(body===undefined?{}:{body:body instanceof Uint8Array?Buffer.from(body):JSON.stringify(body)})});
 let checks=0;const check=async(name:string,fn:()=>Promise<void>)=>{await fn();console.log("PASS "+name);checks++;};
 try{
  await store.writeCollection("users",[{id:"u",email:"u@fixture.invalid",passwordHash:"unused",role:"user",createdAt:now}]);
  await store.writeCollection("devices",[{id:"d",userId:"u",tokenHash:sha256Hex(token),name:"source",role:"factory",pairedAt:now,lastSeenAt:now},{id:"e",userId:"u",tokenHash:sha256Hex(foreign),name:"other",role:"worker",pairedAt:now,lastSeenAt:now}]);
  await store.writeCollection("profiles",[{id:"p",profileId:"profile-a",userId:"u",deviceId:"d",appType:"reddit",nickname:"Research",lastSeenAt:now}]);
  const bytes=Buffer.alloc(6*chunk+101,17);const parts:Buffer[]=[];for(let offset=0;offset<bytes.length;offset+=chunk)parts.push(bytes.subarray(offset,offset+chunk));
  const metadata={containerId:"profile-a",size:bytes.length,checksum:hash(bytes),iv:Buffer.alloc(12).toString("base64"),salt:Buffer.alloc(16).toString("base64"),parts:parts.map(hash)};
  const started=await transfer.POST(req("POST",metadata));assert.equal(started.status,200);const id=(await started.json()).uploadId;
  await check("6 MiB transfer remains invisible and incomplete until every part is acknowledged",async()=>{
   assert.deepEqual((await(await list.GET(req("GET"))).json()).backups,[]);
   assert.equal((await item.GET(req("GET"),{params:{id}})).status,404);
   assert.equal((await transfer.POST(req("POST",{complete:id}))).status,409);
  });
  await check("ownership, bounds and checksums reject bad parts without acknowledgements",async()=>{
   for(const [query,body,status,auth] of [[`?id=${id}&part=0`,parts[0],401,foreign],[`?id=${id}&part=0`,Buffer.alloc(chunk,18),400,token],[`?id=${id}&part=999`,parts[0],400,token],[`?id=${id}&part=0&part=1`,parts[0],400,token]] as const)
    assert.equal((await transfer.PUT(req("PUT",body,query,auth))).status,status);
   assert.deepEqual((await store.readCollection<BackupRecord>("backups"))[0].upload!.received,[]);
  });
  await check("out-of-order and repeated parts do not duplicate receipt counts",async()=>{
   for(const index of [6,3,1,0,2,5,4,0])assert.equal((await transfer.PUT(req("PUT",parts[index],`?id=${id}&part=${index}`))).status,200);
   assert.equal((await store.readCollection<BackupRecord>("backups"))[0].upload!.received.length,parts.length);
   for(let retry=0;retry<2;retry++)assert.equal((await transfer.POST(req("POST",{complete:id}))).status,200);
   assert.equal((await(await list.GET(req("GET"))).json()).backups.length,1);
  });
  await check("manifest and each download stay below host limit and reassemble byte-for-byte",async()=>{
   const response=await item.GET(req("GET",undefined,"?transfer=1"),{params:{id}});assert.equal(response.status,200);
   const manifest=await response.json();assert.equal(manifest.transport,"chunks-v1");assert(!JSON.stringify(manifest).includes("key"));
   const downloaded=[];for(let i=0;i<parts.length;i++){
    const result=await item.GET(req("GET",undefined,`?transfer=1&part=${i}`),{params:{id}});assert.equal(result.headers.get("cache-control"),"no-store");
    const bytes=Buffer.from(await result.arrayBuffer());assert(bytes.length<=chunk);assert.equal(hash(bytes),manifest.parts[i].checksum);downloaded.push(bytes);
   }
   assert.deepEqual(Buffer.concat(downloaded),bytes);assert.equal(hash(Buffer.concat(downloaded)),manifest.checksum);
   assert.equal((await item.GET(req("GET"),{params:{id}})).status,409);
   assert.equal((await item.GET(req("GET",undefined,"?transfer=1&part=0",foreign),{params:{id}})).status,401);
  });
  await check("expired transfer never publishes and is cleaned without deleting a completed backup",async()=>{
   const other=(await(await transfer.POST(req("POST",metadata))).json()).uploadId;
   await transfer.PUT(req("PUT",parts[0],`?id=${other}&part=0`));
   let key="";await store.mutateCollection<BackupRecord>("backups",rows=>rows.map(b=>{if(b.id!==other)return b;key=b.chunks![0].key;return {...b,upload:{...b.upload!,expiresAt:Date.now()-300000}};}));
   assert.equal((await transfer.POST(req("POST",{complete:other}))).status,409);
   assert.equal((await transfer.PUT(req("PUT",parts[1],`?id=${other}&part=1`))).status,401);
   await transfer.POST(req("POST",metadata));assert.equal(await store.getBlob(key),null);
   assert.equal((await item.GET(req("GET",undefined,"?transfer=1&part=0"),{params:{id}})).status,200);
  });
  await check("delete removes every encrypted part, preserves unrelated pending work",async()=>{
   const before=await store.readCollection<BackupRecord>("backups"),keys=before.find(b=>b.id===id)!.chunks!.map(p=>p.key);
   assert.equal((await item.DELETE(req("DELETE"),{params:{id}})).status,200);
   for(const key of keys)assert.equal(await store.getBlob(key),null);
   assert.equal((await store.readCollection<BackupRecord>("backups")).length,before.length-1);
  });
  await check("private part cleanup bounds concurrency and waits for in-flight failures",async()=>{
   const {deleteBackupParts}=await import("../src/lib/backup-transfer");let live=0,max=0,finished=0;
   const parts=Array.from({length:20},(_,i)=>({key:String(i),checksum:"unused",size:1}));
   await assert.rejects(deleteBackupParts(parts,{deleteBlob:async(key)=>{live++;max=Math.max(max,live);await new Promise(resolve=>setTimeout(resolve,5));live--;finished++;if(key==="0")throw new Error("fixture");}}));
   assert.equal(live,0);assert.equal(max,8);assert.equal(finished,8);
  });
  console.log(`${checks} chunked backup route groups passed`);
 }finally{process.chdir(cwd);await fs.rm(tmp,{recursive:true,force:true});}
}
main().catch(error=>{console.error(error);process.exitCode=1;});
