import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { attestRelease, emptyReleaseState, promoteRelease, publicRelease, releaseBlockers, RELEASE_CHECKS,
  validateCandidate, versionSequence, type Candidate, type ReleaseCheck } from "../src/lib/socialbox-release-policy";
import catalog from "../src/data/socialbox-releases.json";
const sha = "a".repeat(64), at = "2026-09-28T12:00:00.000Z";
const bytes = Buffer.from("synthetic repository fixture\n");
const file = { base64: bytes.toString("base64"), sha256: createHash("sha256").update(bytes).digest("hex") };
const candidate: Candidate = { id: "socialbox-16", sequence: 16, packageVersion: "3.1.0-1+socialbox.16", sha256: sha,
  size: 1024, architecture: "iphoneos-arm64", minimumIOS: "16.0", supportedFrom: ["3.1.0-1+socialbox.15"], notes: "Synthetic update",
  commit: "1".repeat(40), blockers: [], artifactURL: `https://fixture.public.blob.vercel-storage.com/apt/socialbox/artifacts/${sha}/socialbox_16_iphoneos-arm64.deb`,
  files: Object.fromEntries(["Release", "InRelease", "Release.gpg", "Packages", "Packages.gz", "key.asc", `by-hash/SHA256/${file.sha256}`].map(k => [k, file])) };
const checks = Object.fromEntries(RELEASE_CHECKS.map(k => [k, `Synthetic observation for ${k}; not a device claim.`])) as Record<ReleaseCheck, string>;
let count = 0;
const test = async (name: string, run: () => void | Promise<void>) => { await run(); count++; console.log(`PASS ${name}`); };
async function main() {
  process.env.ADMIN_EMAIL = "owner@fixture.invalid";
  await test("canonical version ordering, not lexicographic", () => {
    assert.equal(versionSequence("3.1.0-1+socialbox.16"),16);
    for (const v of ["3.1.0-1+socialbox.016", "16", "3.1.0-1+socialbox.16\n", null]) assert.equal(versionSequence(v),null);
  });
  await test("empty stable channel is not a release", () => assert.equal(publicRelease(undefined, emptyReleaseState()).available,false));
  for (const patch of [{ supportedFrom: ["3.1.0-1+socialbox.12"] }, { architecture: "iphoneos-arm" }, { sha256: "bad" },
    { artifactURL: "https://evil.invalid/app.deb" }, { artifactURL: candidate.artifactURL+"?token=x" }, { sequence: 17 }])
    await test(`candidate rejects ${Object.keys(patch)[0]}`, () => assert.throws(() => validateCandidate({ ...candidate, ...patch } as Candidate)));
  const tested = attestRelease(emptyReleaseState(),candidate,checks,"owner",at);
  await test("package is blocked before device receipt", () => assert.throws(() => promoteRelease(emptyReleaseState(),candidate,[candidate],0,"owner",at)));
  await test("partial acceptance cannot enable Release", () => assert.throws(() => attestRelease(emptyReleaseState(),candidate,{ ...checks, upgrade_data: "" },"owner",at)));
  await test("test receipt is bound to package hash", () => assert(releaseBlockers({ ...candidate, sha256:"b".repeat(64) },tested).length));
  await test("engineering blocker cannot be overridden by passing checkboxes", () => assert.throws(() => promoteRelease(tested,{...candidate,blockers:["License activation not implemented"]},[candidate],1,"owner",at)));
  await test("missing immutable snapshot blocks release", () => assert.throws(() => promoteRelease(tested,{ ...candidate, files:{} },[candidate],1,"owner",at)));
  await test("stale review cannot promote", () => assert.throws(() => promoteRelease(tested,candidate,[candidate],0,"owner",at)));
  const released = promoteRelease(tested,candidate,[candidate],1,"owner",at);
  await test("exact tested artifact becomes stable without rebuild", () => {
    assert.equal(released.current,candidate.id); assert.equal(publicRelease(candidate,released).sha256,sha);
    assert.deepEqual(promoteRelease(released,candidate,[candidate],1,"owner",at),released);
  });
  await test("unknown stable baseline blocks upgrades", () => assert.throws(() => promoteRelease({ ...tested,current:"missing" },candidate,[candidate],1,"owner",at)));
  await test("public API omits private test notes, actors and build blockers", () => {
    const result=JSON.stringify(publicRelease(candidate,released));
    for (const secret of ["owner", "observation", "checks", "receipts"]) assert(!result.includes(secret));
    assert.equal(publicRelease(candidate,released).updateURL,"https://redditspoof.vercel.app/updates");
  });
  const scratch = await fs.mkdtemp(path.join(os.tmpdir(),"socialbox-release-test-")), cwd=process.cwd();
  const saved = [...catalog.candidates];
  process.chdir(scratch); delete process.env.BLOB_READ_WRITE_TOKEN; process.env.JWT_SECRET="synthetic-release-test-secret";
  try {
    const { getStorage }=await import("../src/lib/storage"), storage=getStorage();
    const { createSessionToken }=await import("../src/lib/auth");
    await storage.writeCollection("users", [{ id:"owner",email:"owner@fixture.invalid",passwordHash:"unused",role:"admin",licensedAt:null,createdAt:at },
      { id:"customer",email:"customer@fixture.invalid",passwordHash:"unused",role:"user",licensedAt:null,createdAt:at }]);
    const owner=await createSessionToken({id:"owner",email:"owner@fixture.invalid",username:"owner",licensed:true,role:"admin"});
    const customer=await createSessionToken({id:"customer",email:"customer@fixture.invalid",username:"customer",licensed:true,role:"user"});
    const admin=await import("../src/app/api/admin/releases/route"), latest=await import("../src/app/api/releases/socialbox/latest/route");
    const apt=await import("../src/app/apt/socialbox/[...path]/route");
    const req=(token?:string,body?:unknown,origin="https://fixture.invalid")=>new Request("https://fixture.invalid/api/admin/releases",{method:body?"POST":"GET",headers:{
      ...(token?{cookie:`socialbox_session=${token}`}:{ }),"content-type":"application/json",origin},...(body?{body:JSON.stringify(body)}:{})});
    await test("anonymous and customer cannot access release controls", async()=>{for(const token of [undefined,customer]) assert.equal((await admin.GET(req(token))).status,403);});
    await test("cross-origin admin mutation rejected", async()=>assert.equal((await admin.POST(req(owner,{action:"release"},"https://evil.invalid"))).status,403));
    await test("unknown candidate cannot be published", async()=>assert.equal((await admin.POST(req(owner,{action:"release",candidateID: "missing", sha256:sha}))).status,409));
    await test("empty channel API no-store and APT404", async()=>{
      const response=await latest.GET(); assert.equal(response.headers.get("cache-control"),"no-store"); assert.equal((await response.json()).available,false);
      assert.equal((await apt.GET(req(),{params:{path:["Release"]}})).status,404);
    });
    catalog.candidates.splice(0,catalog.candidates.length,...([candidate] as typeof catalog.candidates));
    await test("admin receipt then release through real storage routes",async()=>{
      assert.equal((await admin.POST(req(owner,{ action:"attest",candidateID:candidate.id,sha256:sha,checks }))).status,200);
      const response=await admin.POST(req(owner,{ action:"release",candidateID:candidate.id,sha256:sha,revision:1 }));assert.equal(response.status,200);
      assert.equal((await (await latest.GET()).json()).packageVersion,candidate.packageVersion);
    });
    await test("concurrent repeated release has one public history event",async()=>{
      const responses=await Promise.all(Array.from({length:6},()=>admin.POST(req(owner,{action:"release",candidateID:candidate.id,sha256:sha,revision:1}))));
      assert(responses.every(r=>r.status===200));
      const {state}=await (await admin.GET(req(owner))).json();assert.equal(state.history.length,1);
    });
    await test("published APT bytes and artifact target are exact",async()=>{
      assert.equal(await (await apt.GET(req(),{params:{path:["Release"]}})).text(),bytes.toString());
      assert.equal((await apt.GET(req(),{params:{path:["pool",sha,"socialbox_16_iphoneos-arm64.deb"]}})).headers.get("location"),candidate.artifactURL);
      assert.equal((await apt.GET(req(),{params:{path:["..","private"]}})).status,404);
      assert.equal(await (await apt.GET(req(),{params:{path:["by-hash","SHA256",file.sha256]}})).text(),bytes.toString());
    });
    await test("unknown hash URL never redirects",async()=>assert.equal((await apt.GET(req(),{params:{path:["pool","b".repeat(64),"socialbox_16_iphoneos-arm64.deb"]}})).status,404));
    await test("tampered bundled snapshot fails closed",async()=>{
      const original=candidate.files.Release;candidate.files.Release={...original,sha256:"b".repeat(64)};
      try {assert.equal((await latest.GET()).status,503);assert.equal((await apt.GET(req(),{params:{path:["Release"]}})).status,503);}finally{candidate.files.Release=original;}
    });
    await test("release storage does not touch users or keys",async()=>{assert.equal((await storage.readCollection("users")).length,2);assert.deepEqual(await storage.readCollection("licenses"),[]);});
  } finally { catalog.candidates.splice(0,catalog.candidates.length,...saved);process.chdir(cwd);await fs.rm(scratch,{recursive:true,force:true}); }
  console.log(`PASS ${count} SocialBox release checks; synthetic fixtures only, no real device acceptance.`);
}
main().catch(e=>{console.error(e);process.exitCode=1;});
