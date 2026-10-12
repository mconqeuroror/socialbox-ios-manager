/** Edge-safe owner policy shared by the browser gate and fresh server checks.
 * Keep the seeded identity stable; customer/app authentication is separate.
 */
export function adminUsernameFromEnv(): string {
  return (process.env.ADMIN_USERNAME?.trim() || "typekpaco").toLowerCase();
}

export function adminEmailFromEnv(): string {
  return process.env.ADMIN_EMAIL?.trim().toLowerCase() || `${adminUsernameFromEnv()}@redditbox.local`;
}

export function isConsoleOwner(user: { email?: unknown; role?: unknown } | null | undefined): boolean {
  return user?.role === "admin" && typeof user.email === "string" &&
    user.email.trim().toLowerCase() === adminEmailFromEnv();
}

export class ConsoleOwnerRequiredError extends Error {
  constructor() { super("Owner access required"); }
}

/** Check the exact actor in each fresh transaction snapshot, including retries. */
export function requireCurrentConsoleOwner(
  users: readonly { id: string; email?: unknown; role?: unknown }[], actorUserId: string
): void {
  const matches = users.filter((user) => user.id === actorUserId);
  if (!actorUserId || matches.length !== 1 || !isConsoleOwner(matches[0]))
    throw new ConsoleOwnerRequiredError();
}
