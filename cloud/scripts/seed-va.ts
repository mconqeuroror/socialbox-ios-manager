/**
 * Creates a test "VA" (operator) user for smoke testing.
 * Usage: npm run seed:va -- [email] [password]
 */
import { randomBytes } from "node:crypto";
import bcrypt from "bcryptjs";
import { getStorage, type UserRecord } from "../src/lib/storage";

const email = (process.argv[2] || "va@redditbox.test").toLowerCase();
const password = process.argv[3] || "va-secret-456";

async function main(): Promise<void> {
  const storage = getStorage();
  const user: UserRecord = {
    id: randomBytes(8).toString("hex"),
    email,
    passwordHash: await bcrypt.hash(password, 10),
    role: "user",
    licensedAt: null,
    createdAt: new Date().toISOString(),
  };
  const committed = await storage.mutateCollection<UserRecord>("users", (items) => {
    // This check runs on every CAS retry and under the local cross-process lock.
    // Migration and seeding therefore use the same authoritative auth document.
    if (items.some((existing) => existing.email === email)) return items;
    return [...items, user];
  });
  if (!committed.some((existing) => existing.id === user.id)) {
    console.log(`User ${email} already exists.`);
    return;
  }
  console.log(`Created user: ${email} / ${password}`);
}

main().catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
