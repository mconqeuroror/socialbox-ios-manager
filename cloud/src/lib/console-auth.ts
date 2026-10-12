import { getUserFromRequest, verifySessionToken } from "./auth";
import { isConsoleOwner } from "./console-owner";

/** Both helpers re-read storage. Cached JWT roles/emails never authorize the console. */
export async function getConsoleOwnerFromRequest(req: Request) {
  const user = await getUserFromRequest(req);
  return isConsoleOwner(user) ? user : null;
}

export async function getConsoleOwnerFromToken(token: string | undefined) {
  const user = token ? await verifySessionToken(token) : null;
  return isConsoleOwner(user) ? user : null;
}
