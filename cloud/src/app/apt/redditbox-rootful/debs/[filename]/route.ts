import { createAptDownloadHandler } from "@/lib/apt-download";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const GET = createAptDownloadHandler("iphoneos-arm");
export const HEAD = GET;
