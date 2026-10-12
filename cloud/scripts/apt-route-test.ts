/** Actual unauthenticated Next route with a bounded synthetic bundled manifest. */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
async function main() {
  const cloud = path.resolve(path.dirname(process.argv[1]), ".."), parent = path.resolve(cloud, "../..");
  const scratch = await fs.mkdtemp(path.join(parent, "apt-route-test-")), previous = process.cwd();
  process.chdir(scratch); delete process.env.APT_BLOB_HOST;
  const route = await import("../src/app/apt/redditbox/debs/[filename]/route");
  const manifestPath = path.join(scratch, "public/apt/redditbox/repository.json");
  const filename = "com.redditbox_1.2.3_iphoneos-arm64.deb", digest = "a".repeat(64), host = "aptfixture.public.blob.vercel-storage.com";
  const url = `https://${host}/apt/redditbox/debs/${digest}/${filename}`;
  const manifest = { formatVersion: 1, package: "com.redditbox", architecture: "iphoneos-arm64", version: "1.2.3", blobHost: host,
    versions: [{ version: "1.2.3", filename: `debs/${filename}`, sha256: digest, size: 50, blobURL: url,
      control: { Package: "com.redditbox", Version: "1.2.3", Architecture: "iphoneos-arm64" } }] };
  const request = new Request(`https://console.invalid/apt/redditbox/debs/${filename}`);
  try {
    assert.equal((await route.GET(request, { params: { filename } })).status, 404);
    await fs.mkdir(path.dirname(manifestPath), { recursive: true }); await fs.writeFile(manifestPath, JSON.stringify(manifest));
    const response = await route.GET(request, { params: { filename } }); assert.equal(response.status, 302);
    assert.equal(response.headers.get("location"), url); assert.equal(response.headers.get("cache-control"), "no-store");
    assert.equal((await route.HEAD(request, { params: { filename } })).status, 302);
    for (const [packageID, version] of [["ai.akemi.appinst", "2.1.1-redditbox1"], ["ai.akemi.appsyncunified", "116.0"]]) {
      const dependencyFilename = `${packageID}_${version}_iphoneos-arm64.deb`;
      const dependency = { version, filename: `debs/${dependencyFilename}`, sha256: digest, size: 50,
        blobURL: `https://${host}/apt/redditbox/debs/${digest}/${dependencyFilename}`,
        control: { Package: packageID, Version: version, Architecture: "iphoneos-arm64" } };
      const withDependency = { ...manifest, dependencies: [dependency] };
      await fs.writeFile(manifestPath, JSON.stringify(withDependency));
      const download = await route.GET(request, { params: { filename: dependencyFilename } });
      assert.equal(download.status, 302); assert.equal(download.headers.get("location"), dependency.blobURL);
      dependency.blobURL = "https://evil.invalid/dependency.deb";
      await fs.writeFile(manifestPath, JSON.stringify(withDependency));
      assert.equal((await route.GET(request, { params: { filename: dependencyFilename } })).status, 503);
    }
    await fs.writeFile(manifestPath, JSON.stringify(manifest));
    const rootful = await import("../src/app/apt/redditbox-rootful/debs/[filename]/route");
    const rootfulFilename = filename.replace("iphoneos-arm64", "iphoneos-arm");
    const rootfulManifest = JSON.parse(JSON.stringify(manifest).replaceAll("iphoneos-arm64", "iphoneos-arm").replaceAll("/apt/redditbox/", "/apt/redditbox-rootful/"));
    const rootfulPath = path.join(scratch, "public/apt/redditbox-rootful/repository.json");
    await fs.mkdir(path.dirname(rootfulPath), { recursive: true });
    await fs.writeFile(rootfulPath, JSON.stringify(rootfulManifest));
    const rootfulResponse = await rootful.GET(request, { params: { filename: rootfulFilename } });
    assert.equal(rootfulResponse.status, 302);
    assert.equal(rootfulResponse.headers.get("location"), rootfulManifest.versions[0].blobURL);
    assert.equal((await rootful.GET(request, { params: { filename } })).status, 404);
    assert.equal((await route.GET(request, { params: { filename: rootfulFilename } })).status, 404);
    await fs.writeFile(rootfulPath, JSON.stringify(manifest));
    assert.equal((await rootful.GET(request, { params: { filename: rootfulFilename } })).status, 503);
    for (const name of ["../repository.json", "com.redditbox_0.1.0_iphoneos-arm64.deb", "https://evil.invalid/file.deb"])
      assert.equal((await route.GET(request, { params: { filename: name } })).status, 404);
    process.env.APT_BLOB_HOST = "other.public.blob.vercel-storage.com";
    assert.equal((await route.GET(request, { params: { filename } })).status, 503); delete process.env.APT_BLOB_HOST;
    manifest.versions[0].blobURL = "https://evil.invalid/file.deb"; await fs.writeFile(manifestPath, JSON.stringify(manifest));
    assert.equal((await route.GET(request, { params: { filename } })).status, 503);
    await fs.writeFile(manifestPath, "corrupt"); assert.equal((await route.GET(request, { params: { filename } })).status, 503);
    const admin = await import("../src/app/api/admin/licenses/route");
    assert.equal((await admin.GET(new Request("https://console.invalid/api/admin/licenses"))).status, 403);
    console.log("APT public route checks passed: listed GET/HEAD302, absent/traversal404, corrupt/mismatched503, admin still protected");
  } finally {
    process.chdir(previous);
    const relative = path.relative(parent, scratch);
    assert(!path.isAbsolute(relative) && !relative.includes(path.sep) && relative.startsWith("apt-route-test-"));
    await fs.rm(scratch, { recursive: true, force: true });
  }
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
