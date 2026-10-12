/**
 * Seed script: upserts the admin account from ADMIN_USERNAME / ADMIN_PASSWORD
 * (optional ADMIN_EMAIL). Run with: npm run seed
 * Login also lazily seeds on first attempt.
 */
import "dotenv/config";
import { adminEmailFromEnv, adminUsernameFromEnv, ensureAdminSeeded } from "../lib/admin";

async function main() {
  await ensureAdminSeeded();
  console.log(`Admin account ensured: ${adminUsernameFromEnv()} (${adminEmailFromEnv()})`);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
