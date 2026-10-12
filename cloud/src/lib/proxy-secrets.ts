import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

function key(): Buffer {
  const raw = process.env.PROXY_SECRETS_KEY?.trim() ?? "";
  const decoded = /^[0-9a-fA-F]{64}$/.test(raw)
    ? Buffer.from(raw, "hex")
    : Buffer.from(raw, "base64");
  if (decoded.length !== 32) {
    throw new Error("PROXY_SECRETS_KEY must be 32 bytes (hex or base64)");
  }
  return decoded;
}

export function encryptProxySecret(value: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key(), iv);
  const ciphertext = Buffer.concat([cipher.update(value, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return ["v1", iv.toString("base64url"), tag.toString("base64url"),
    ciphertext.toString("base64url")].join(".");
}

export function decryptProxySecret(envelope: string): string {
  const [version, ivText, tagText, ciphertextText] = envelope.split(".");
  if (version !== "v1" || !ivText || !tagText || !ciphertextText) {
    throw new Error("Invalid encrypted proxy secret");
  }
  const decipher = createDecipheriv("aes-256-gcm", key(),
    Buffer.from(ivText, "base64url"));
  decipher.setAuthTag(Buffer.from(tagText, "base64url"));
  return Buffer.concat([
    decipher.update(Buffer.from(ciphertextText, "base64url")),
    decipher.final(),
  ]).toString("utf8");
}
