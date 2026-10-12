import type { UserRecord } from "./storage";

const LOCAL_DOMAIN = "redditbox.local";

export function usernameFromEmail(email: string): string {
  const at = email.indexOf("@");
  return at > 0 ? email.slice(0, at) : email;
}

export function loginCandidates(identifier: string): string[] {
  const raw = identifier.toLowerCase().trim();
  if (!raw) return [];
  const out = [raw];
  if (!raw.includes("@")) {
    out.push(`${raw}@${LOCAL_DOMAIN}`);
  }
  return out;
}

export function findUserByLogin(users: UserRecord[], identifier: string): UserRecord | undefined {
  const candidates = loginCandidates(identifier);
  const local = identifier.toLowerCase().trim();
  return users.find((u) => {
    if (candidates.includes(u.email)) return true;
    if (u.username && u.username.toLowerCase() === local) return true;
    return usernameFromEmail(u.email).toLowerCase() === local;
  });
}
