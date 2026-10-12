"use client";

export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <main className="flex flex-1 flex-col items-center justify-center px-4 py-16 text-center">
      <p className="text-6xl font-black tracking-tight text-red-600">500</p>
      <h1 className="mt-3 text-xl font-bold">Something went wrong</h1>
      <p className="mt-1 text-sm text-slate-500 dark:text-slate-400">
        {error.message || "An unexpected error occurred."}
      </p>
      <button type="button" onClick={reset} className="btn-primary mt-6">
        Try again
      </button>
    </main>
  );
}
