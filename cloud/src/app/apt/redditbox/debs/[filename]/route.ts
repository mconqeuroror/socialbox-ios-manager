import { createAptDownloadHandler } from "@/lib/apt-download";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const GET = createAptDownloadHandler("iphoneos-arm64");
export const HEAD = GET;
