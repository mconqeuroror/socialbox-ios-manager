import fs from "node:fs/promises";
import path from "node:path";
import { checkedRepository, repositoryName } from "./apt-policy.mjs";

export type InstallationSource = { architecture: string; available: boolean; version?: string; url?: string; sileoURL?: string };

export async function installationSource(architecture: string, root = process.cwd(), origin = process.env.APP_URL, blobHost = process.env.APT_BLOB_HOST): Promise<InstallationSource> {
  const unavailable = { architecture, available: false };
  try {
    if (!origin || !blobHost) return unavailable;
    const canonical = new URL(origin);
    if (canonical.protocol !== "https:" || canonical.username || canonical.password || canonical.port ||
        canonical.pathname !== "/" || canonical.search || canonical.hash) return unavailable;
    const repository = repositoryName(architecture);
    const directory = path.join(root, "public", "apt", repository);
    const manifestPath = path.join(directory, "repository.json");
    if ((await fs.stat(manifestPath)).size > 512 * 1024) return unavailable;
    const manifest = checkedRepository(JSON.parse(await fs.readFile(manifestPath, "utf8")), blobHost, architecture);
    // The release driver verifies signatures and downloads before promotion.
    // An unpublished/incomplete snapshot must never expose installation buttons.
    for (const name of ["InRelease", "Release.gpg", "Packages", "public-key.asc", "redditbox-archive-keyring.gpg"]) {
      const info = await fs.stat(path.join(directory, name));
      if (!info.isFile() || !info.size) return unavailable;
    }
    const url = `${canonical.origin}/apt/${repository}/`;
    return { architecture, available: true, version: manifest.version, url, sileoURL: `sileo://source/${url}` };
  } catch { return unavailable; }
}
