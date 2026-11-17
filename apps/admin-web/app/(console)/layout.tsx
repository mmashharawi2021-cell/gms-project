import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import Shell from "@/components/Shell";
import { RT } from "@/lib/server";

export default async function ConsoleLayout({ children }: { children: React.ReactNode }) {
  // Cheap server-side gate (no session cookie -> login). Real authorization is enforced by the API on every call.
  if (!(await cookies()).get(RT)) redirect("/login");
  return <Shell>{children}</Shell>;
}
