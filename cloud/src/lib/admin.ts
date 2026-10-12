import { getStorage, type UserRecord, type Role } from "./storage";
import { hashPassword, verifyPassword } from "./auth";
import { nowIso, randomId } from "./ids";
import { usernameFromEmail } from "./identity";

import { adminEmailFromEnv, adminUsernameFromEnv } from "./console-owner";
export { adminEmailFromEnv, adminUsernameFromEnv } from "./console-owner";

export function adminPasswordFromEnv(): string {
  return process.env.ADMIN_PASSWORD || "";
}

/**
 * Ensure the seed admin account exists and stays admin.
 * Idempotent upsert: creates on first run, then keeps role/password in sync
 * with ADMIN_USERNAME / ADMIN_PASSWORD / ADMIN_EMAIL.
 */
export async function ensureAdminSeeded(): Promise<void> {
  const email = adminEmailFromEnv();
  const username = adminUsernameFromEnv();
  const password = adminPasswordFromEnv();
  if (!email || !password) return;

  const storage = getStorage();
  const users = await storage.readCollection<UserRecord>("users");
  const existing =
    users.find((u) => u.email === email) ||
    users.find((u) => (u.username || usernameFromEmail(u.email)).toLowerCase() === username);

  if (!existing) {
    const admin: UserRecord = {
      id: randomId(8),
      email,
      username,
      passwordHash: await hashPassword(password),
      role: "admin" as Role,
      licensedAt: new Date().toISOString(),
      createdAt: nowIso(),
    };
    await storage.mutateCollection<UserRecord>("users", (items) => [...items, admin]);
    return;
  }

  const passwordOk = await verifyPassword(password, existing.passwordHash);
  const needsRole = existing.role !== "admin";
  const needsEmail = existing.email !== email;
  const needsUsername = existing.username !== username;
  const needsLicense = existing.licensedAt === null;
  if (passwordOk && !needsRole && !needsEmail && !needsUsername && !needsLicense) return;

  const passwordHash = passwordOk ? existing.passwordHash : await hashPassword(password);
  await storage.mutateCollection<UserRecord>("users", (items) =>
    items.map((u) =>
      u.id === existing.id
        ? {
            ...u,
            email,
            username,
            passwordHash,
            role: "admin" as Role,
            licensedAt: u.licensedAt ?? nowIso(),
          }
        : u
    )
  );
}
