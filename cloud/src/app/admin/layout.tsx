import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { SESSION_COOKIE } from "@/lib/auth";
import { getConsoleOwnerFromToken } from "@/lib/console-auth";

export const dynamic = "force-dynamic";

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  if (!await getConsoleOwnerFromToken(cookies().get(SESSION_COOKIE)?.value)) redirect("/login");
  return <>{children}</>;
}
