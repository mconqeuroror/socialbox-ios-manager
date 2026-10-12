import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { installationSource } from '../src/lib/installation';

async function main() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'rbx-install-'));
  const origin = 'https://redditspoof.vercel.app';
  const host = 'fixture.public.blob.vercel-storage.com';
  try {
    for (const architecture of ['iphoneos-arm64', 'iphoneos-arm']) {
      const repo = architecture === 'iphoneos-arm64' ? 'redditbox' : 'redditbox-rootful';
      const dir = path.join(root, 'public/apt', repo);
      const read = (url = origin, store = host) => installationSource(architecture, root, url, store);
      assert.equal((await read()).available, false);
      await fs.mkdir(dir, { recursive: true });
      const filename = `com.redditbox_0.1.1_${architecture}.deb`, sha256 = 'a'.repeat(64);
      const manifest = { formatVersion: 1, package: 'com.redditbox', architecture, version: '0.1.1', blobHost: host,
        versions: [{ version: '0.1.1', filename: `debs/${filename}`, sha256, size: 100,
          blobURL: `https://${host}/apt/${repo}/debs/${sha256}/${filename}`,
          control: { Package: 'com.redditbox', Version: '0.1.1', Architecture: architecture } }] };
      await fs.writeFile(path.join(dir, 'repository.json'), JSON.stringify(manifest));
      assert.equal((await read()).available, false);
      for (const name of ['InRelease', 'Release.gpg', 'Packages', 'public-key.asc', 'redditbox-archive-keyring.gpg'])
        await fs.writeFile(path.join(dir, name), 'fixture');
      const source = await read();
      assert.equal(source.available, true);
      assert.equal(source.sileoURL, `sileo://source/${origin}/apt/${repo}/`);
      assert.equal(source.version, '0.1.1');
      assert.equal((await read(origin, 'wrong.public.blob.vercel-storage.com')).available, false);
      for (const invalid of ['http://redditspoof.vercel.app', origin + '/path', origin + '?x=1', 'https://user:pass@redditspoof.vercel.app'])
        assert.equal((await read(invalid)).available, false);
      await fs.writeFile(path.join(dir, 'repository.json'), '{corrupt');
      assert.equal((await read()).available, false);
    }
    console.log('Installation checks passed: both architectures, canonical Sileo URLs, unpublished/incomplete/corrupt/store mismatch hidden.');
  } finally { await fs.rm(root, { recursive: true, force: true }); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
