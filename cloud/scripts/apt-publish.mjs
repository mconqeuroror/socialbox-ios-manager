#!/usr/bin/env node
import { aptPublisherConfiguration, createAptPublisher } from "./apt-publisher.mjs";
import { AptPolicyError } from "../src/lib/apt-policy.mjs";

async function main() {
  const [command, ...args] = process.argv.slice(2), values = {};
  if (!["lock", "check", "upload", "unlock"].includes(command) || args.length % 2)
    throw new AptPolicyError("Usage: apt-publish.mjs lock --owner UUID | check --owner UUID --etag ETAG | upload --owner UUID --etag ETAG --file PATH --pathname PATH | unlock --owner UUID --etag ETAG");
  const allowed = command === "upload" ? ["owner", "etag", "file", "pathname"] : ["unlock", "check"].includes(command) ? ["owner", "etag"] : ["owner"];
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i].replace(/^--/, "");
    if (!args[i].startsWith("--") || !allowed.includes(key) || key in values || !args[i + 1])
      throw new AptPolicyError("Unexpected or duplicate APT publisher argument");
    values[key] = args[i + 1];
  }
  if (allowed.some((key) => !(key in values))) throw new AptPolicyError("Missing required APT publisher argument");
  const configuration = aptPublisherConfiguration();
  const publisher = createAptPublisher(await import("@vercel/blob"), configuration);
  const result = command === "lock" ? await publisher.lock(values.owner) : command === "check" ? await publisher.check(values.owner, values.etag) : command === "unlock"
    ? await publisher.unlock(values.owner, values.etag) : await publisher.upload(values);
  process.stdout.write(JSON.stringify(result) + "\n");
}
main().catch((error) => {
  // SDK errors can contain request context. Keep credentials out of stdout,
  // release journals, shell logs and exception reports.
  process.stderr.write((error instanceof AptPolicyError ? error.message :
    "APT Blob operation failed. Retain the release journal and lock; inspect configuration before retrying.") + "\n");
  process.exitCode = 1;
});
