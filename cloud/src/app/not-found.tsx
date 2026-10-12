import Link from "next/link";

export default function NotFound() {
  return (
    <main className="flex flex-1 flex-col items-center justify-center px-4 py-16 text-center">
      <p className="text-6xl font-black tracking-tight text-[#007AFF]">404</p>
      <h1 className="mt-3 text-xl font-bold">Page not found</h1>
      <p className="mt-1 text-sm text-slate-500 dark:text-slate-400">
        The page you were looking for does not exist.
      </p>
      <Link href="/" className="btn-primary mt-6">
        Back home
      </Link>
    </main>
  );
}
