/** Upload a prepared candidate, never release it. No license/signing secrets enter the catalog. */
import fs from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import * as blob from "@vercel/blob";
import { aptPublisherConfiguration, createAptPublisher } from "./apt-publisher.mjs";
import { validateCandidate, type Candidate } from "../src/lib/socialbox-release-policy";
import { validateRepositorySnapshot } from "../src/lib/socialbox-releases";
const args = process.argv.slice(2);
async function main() {
  if (args.length !== 3) throw new Error("Usage: tsx scripts/register-socialbox-release.ts CANDIDATE.json PACKAGE.deb PRIVATE-JOURNAL.json");
  const [input, file, journalPath] = args.map(v => path.resolve(v));
  const catalogPath = path.resolve(path.dirname(process.argv[1]), "../src/data/socialbox-releases.json");
  const candidate: Candidate = JSON.parse(await fs.readFile(input, "utf8")); validateCandidate(candidate); validateRepositorySnapshot(candidate);
  const config = aptPublisherConfiguration();
  if (!candidate.artifactURL || new URL(candidate.artifactURL).hostname !== config.host) throw new Error("Prepared package does not match the dedicated public store");
  const artifactPath = new URL(candidate.artifactURL).pathname.slice(1);
  const publisher = createAptPublisher(blob, config, { artifactPolicy: (value: string) => {
    if (value !== artifactPath) throw new Error("Only this prepared artifact can be uploaded");
    return { sha256: candidate.sha256, filename: path.basename(artifactPath) };
  } });
  let journal: { owner: string; candidate: string; sha256: string; phase: string; etag?: string };
  try { journal = JSON.parse(await fs.readFile(journalPath, "utf8")); }
  catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
    journal = { owner: randomUUID(), candidate: candidate.id, sha256: candidate.sha256, phase: "prepared" };
    await fs.writeFile(journalPath, JSON.stringify(journal), { flag: "wx", mode: 0o600 });
  }
  if (journal.candidate !== candidate.id || journal.sha256 !== candidate.sha256) throw new Error("Journal belongs to another candidate");
  if (journal.phase === "complete") { console.log("Candidate already registered. Review its test results in Admin → App releases."); return; }
  const save = async () => { const temp = `${journalPath}.tmp`; await fs.writeFile(temp, JSON.stringify(journal), { mode: 0o600 }); await fs.rename(temp, journalPath); };
  const lock = await publisher.lock(journal.owner); journal.etag = lock.etag; journal.phase = "locked"; await save();
  // Failures retain the lock and journal. Resume the same journal; never steal another publisher's lock.
  await publisher.upload({ owner: journal.owner, etag: lock.etag, file, pathname: artifactPath });
  await publisher.check(journal.owner, lock.etag);
  const catalog = JSON.parse(await fs.readFile(catalogPath, "utf8"));
  const existing = catalog.candidates.find((c: Candidate) => c.id === candidate.id);
  if (existing && JSON.stringify(existing) !== JSON.stringify(candidate)) throw new Error("Candidate IDs are immutable. Build a new version instead.");
  if (!existing) catalog.candidates.push(candidate);
  const temp = catalogPath + ".tmp"; await fs.writeFile(temp, JSON.stringify(catalog, null, 2)+"\n"); await fs.rename(temp, catalogPath);
  journal.phase = "registered"; await save();
  await publisher.unlock(journal.owner, lock.etag);
  journal.phase = "complete"; await save();
  console.log(`Registered ${candidate.id}. Commit the catalog, deploy staging, verify, then promote the website. App release still requires device acceptance in Admin → App releases.`);
}
main().catch(() => { console.error("Candidate registration failed. No app release was performed. Retain the private journal and publication lock; check preparation, credentials and candidate immutability before resuming."); process.exitCode = 1; });
