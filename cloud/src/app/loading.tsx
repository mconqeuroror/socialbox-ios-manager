export default function Loading() {
  return (
    <main className="flex flex-1 items-center justify-center">
      <svg className="h-8 w-8 animate-spin text-[#007AFF]" viewBox="0 0 24 24" fill="none" aria-hidden>
        <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
        <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z" />
      </svg>
    </main>
  );
}
