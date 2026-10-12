import { NextResponse } from "next/server";
import { getUserFromRequest } from "@/lib/auth";
import { getDeviceFromRequest } from "@/lib/devices";
import { randomId } from "@/lib/ids";
import { validHTTPProxyURL } from "@/lib/http-proxy";
import {
  decryptProxySecret,
  encryptProxySecret,
} from "@/lib/proxy-secrets";
import {
  getStorage,
  type RotationSettingsRecord,
} from "@/lib/storage";

export const runtime = "nodejs";

function validHeader(value: string): boolean {
  return value.length > 0 && value.length <= 128 &&
    /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(value);
}

function validateURLs(proxyText: string, rotationText: string): string | null {
  try {
    if (!validHTTPProxyURL(proxyText)) {
      return "Proxy URL must use the supported HTTP transport and include a host and explicit port";
    }
    const rotation = new URL(rotationText);
    if (rotation.protocol !== "https:" || !rotation.hostname ||
        rotation.username || rotation.password) {
      return "Rotation URL must be HTTPS and contain no URL credentials";
    }
    return null;
  } catch {
    return "Invalid proxy or rotation URL";
  }
}

export async function GET(req: Request) {
  const user = await getUserFromRequest(req);
  const device = user ? null : await getDeviceFromRequest(req);
  if (!user && !device) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }
  const userId = user?.id ?? device!.userId;
  const records =
    await getStorage().readCollection<RotationSettingsRecord>("rotation-settings");
  const record = records.find((item) => item.userId === userId);
  if (!record) return NextResponse.json({ settings: null });
  if (device) {
    if (record.deviceAccess !== "all-paired") return NextResponse.json({
      error: "Owner must explicitly save and share global settings with paired devices in the console" }, { status: 403 });
    try {
      return NextResponse.json({
        settings: {
          proxyURL: decryptProxySecret(record.proxyURLSecretEnc),
          rotationURL: record.rotationURL,
          authHeader: record.authHeader,
          authorization: record.authorizationSecretEnc
            ? decryptProxySecret(record.authorizationSecretEnc) : "",
          method: record.method,
          updatedAt: record.updatedAt,
        },
      });
    } catch {
      return NextResponse.json({ error: "Stored settings cannot be decrypted" },
        { status: 500 });
    }
  }
  let proxyHost = "";
  try {
    proxyHost = new URL(decryptProxySecret(record.proxyURLSecretEnc)).host;
  } catch {
    proxyHost = "unavailable";
  }
  return NextResponse.json({
    settings: {
      deviceAccess: record.deviceAccess ?? "not-authorized",
      rotationURL: record.rotationURL,
      authHeader: record.authHeader,
      method: record.method,
      proxyHost,
      hasProxyURL: true,
      hasAuthorization: Boolean(record.authorizationSecretEnc),
      updatedAt: record.updatedAt,
    },
  });
}

export async function PUT(req: Request) {
  const user = await getUserFromRequest(req);
  if (!user) {
    return NextResponse.json({ error: "User authentication required" },
      { status: 401 });
  }
  let body: {
    deviceAccess?: unknown;
    proxyURL?: string;
    rotationURL?: string;
    authHeader?: string;
    authorization?: string;
    method?: string;
  };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }
  if (body?.deviceAccess !== "all-paired") return NextResponse.json({
    error: "Explicit deviceAccess=all-paired is required to share global credentials" }, { status: 400 });
  const proxyURL = typeof body.proxyURL === "string" ? body.proxyURL.trim() : "";
  const rotationURL =
    typeof body.rotationURL === "string" ? body.rotationURL.trim() : "";
  const authHeader =
    typeof body.authHeader === "string" ? body.authHeader.trim() : "Authorization";
  const authorization =
    typeof body.authorization === "string" ? body.authorization.trim() : "";
  const method = body.method === "GET" ? "GET" : body.method === "POST" ? "POST" : "";
  const urlError = validateURLs(proxyURL, rotationURL);
  if (urlError || !validHeader(authHeader) || !method ||
      authorization.length > 4096) {
    return NextResponse.json({
      error: urlError ?? "Invalid header, method, or authorization value",
    }, { status: 400 });
  }
  const now = new Date().toISOString();
  let next: RotationSettingsRecord;
  try {
    next = {
      id: randomId(8),
      userId: user.id,
      deviceAccess: "all-paired",
      proxyURLSecretEnc: encryptProxySecret(proxyURL),
      rotationURL,
      authHeader,
      authorizationSecretEnc: authorization
        ? encryptProxySecret(authorization) : null,
      method,
      updatedAt: now,
    };
  } catch {
    return NextResponse.json({ error: "Server secret encryption is unavailable" },
      { status: 500 });
  }
  await getStorage().mutateCollection<RotationSettingsRecord>(
    "rotation-settings",
    (items) => [...items.filter((item) => item.userId !== user.id), next]
  );
  return NextResponse.json({ settings: {
    deviceAccess: "all-paired",
    rotationURL, authHeader, method,
    proxyHost: new URL(proxyURL).host,
    hasProxyURL: true,
    hasAuthorization: Boolean(authorization),
    updatedAt: now,
  }});
}
