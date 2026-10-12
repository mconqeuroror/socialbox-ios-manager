import crypto from "node:crypto";

/**
 * Unambiguous charset for license keys and pairing codes
 * (no 0/O/1/I confusion).
 */
const CHARSET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

export function randomId(bytes: number): string {
  return crypto.randomBytes(bytes).toString("hex");
}

/** e.g. XXXX-XXXX-XXXX-XXXX (4 groups of 4) */
export function generateLicenseKey(): string {
  const groups: string[] = [];
  for (let g = 0; g < 4; g++) {
    let group = "";
    for (let i = 0; i < 4; i++) {
      group += CHARSET[crypto.randomInt(CHARSET.length)];
    }
    groups.push(group);
  }
  return groups.join("-");
}

/** 8 chars, no separators */
export function generatePairingCode(): string {
  let code = "";
  for (let i = 0; i < 8; i++) {
    code += CHARSET[crypto.randomInt(CHARSET.length)];
  }
  return code;
}

/** random 64-char hex token for devices */
export function generateDeviceToken(): string {
  return crypto.randomBytes(32).toString("hex");
}

export function sha256Hex(input: string): string {
  return crypto.createHash("sha256").update(input, "utf8").digest("hex");
}

export function nowIso(): string {
  return new Date().toISOString();
}

export function isValidLicenseKeyFormat(key: string): boolean {
  return /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/.test(
    key
  );
}
