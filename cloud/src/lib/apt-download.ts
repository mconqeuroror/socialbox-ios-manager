import fs from "node:fs/promises";
import path from "node:path";
import { NextResponse } from "next/server";
import { resolveAptDownload, validPackageFilename, repositoryName } from "@/lib/apt-policy.mjs";

export function createAptDownloadHandler(architecture: string) {
  const MANIFEST = path.join(process.cwd(), "public", "apt", repositoryName(architecture), "repository.json");

  /** Public APT downloads use only this deployment's bundled, validated inventory. */
  return async function GET(_req: Request, { params }: { params: { filename: string } }) {
    if (!validPackageFilename(params.filename, architecture)) return new NextResponse("Package not found", { status: 404 });
    let repository: unknown;
    try {
      const info = await fs.stat(MANIFEST);
      if (!info.isFile() || info.size > 512 * 1024) throw new Error("Invalid repository manifest size");
      repository = JSON.parse(await fs.readFile(MANIFEST, "utf8"));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return new NextResponse("Repository not published yet", { status: 404 });
      return new NextResponse("Repository metadata unavailable", { status: 503, headers: { "Cache-Control": "no-store" } });
    }
    try {
      const target = resolveAptDownload(repository, params.filename, process.env.APT_BLOB_HOST || undefined, architecture);
      if (!target) return new NextResponse("Package not found", { status: 404 });
      return NextResponse.redirect(target.url, { status: 302, headers: { "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff" } });
    } catch {
      return new NextResponse("Repository metadata failed validation", { status: 503, headers: { "Cache-Control": "no-store" } });
    }
  };
}
