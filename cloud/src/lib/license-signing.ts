import { createHash, createHmac, createPrivateKey, createPublicKey, sign } from "node:crypto";

export type DeviceLicenseStatus = "active" | "revoked" | "expired" | "invalid";
export const DEVICE_LICENSE_GRACE_SECONDS = 72 * 60 * 60;

export function loadLicenseSigner() {
  const pem = process.env.LICENSE_SIGNING_PRIVATE_KEY?.replace(/\\n/g, "\n");
  if (!pem) throw new Error("LICENSE_SIGNING_PRIVATE_KEY must contain an RSA private PEM key");
  const key = createPrivateKey(pem);
  if (key.asymmetricKeyType !== "rsa" || (key.asymmetricKeyDetails?.modulusLength ?? 0) < 2048)
    throw new Error("Device license signing requires an RSA key of at least 2048 bits");
  const url = new URL(process.env.APP_URL || "");
  if (url.protocol !== "https:" || url.username || url.password || url.pathname !== "/" || url.search || url.hash)
    throw new Error("APP_URL must be the canonical HTTPS origin for device licenses");
  const publicDER = createPublicKey(key).export({ format: "der", type: "pkcs1" });
  const kid = createHash("sha256").update(publicDER).digest("hex");
  const tokenSecret = createHash("sha256").update("RedditBox device token v1\0")
    .update(key.export({ format: "der", type: "pkcs8" })).digest();
  return {
    issuer: url.origin,
    kid,
    deviceToken(licenseId: string, deviceId: string, binding: string): string {
      return createHmac("sha256", tokenSecret).update(JSON.stringify([licenseId, deviceId, binding])).digest("hex");
    },
    issue(input: { deviceId: string; deviceBinding: string; keyFingerprint: string;
      status: DeviceLicenseStatus; nonce: string; expiresAt?: string | null; reason?: string }, now = Date.now()): string {
      const iat = Math.floor(now / 1000);
      const expiry = input.expiresAt ? Math.floor(Date.parse(input.expiresAt) / 1000) : iat + DEVICE_LICENSE_GRACE_SECONDS;
      const exp = input.status === "active" ? Math.min(iat + DEVICE_LICENSE_GRACE_SECONDS, expiry) : iat + 300;
      if (!Number.isSafeInteger(exp)) throw new Error("Invalid license expiry; no entitlement issued");
      const header = Buffer.from(JSON.stringify({ alg: "RS256", typ: "JWT", kid })).toString("base64url");
      const payload = Buffer.from(JSON.stringify({ v: 1, aud: "redditbox-device", iss: url.origin,
        sub: input.deviceId, deviceBinding: input.deviceBinding, keyFingerprint: input.keyFingerprint,
        status: input.status, iat, exp, nonce: input.nonce, ...(input.reason ? { reason: input.reason } : {}) })).toString("base64url");
      const data = `${header}.${payload}`;
      return `${data}.${sign("RSA-SHA256", Buffer.from(data), key).toString("base64url")}`;
    },
  };
}
