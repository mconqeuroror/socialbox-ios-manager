/** Log only bounded error identifiers; never include keys, request bodies or storage data. */
export function reportLicenseServiceError(operation: string, error: unknown) {
  const value = error as { name?: unknown; code?: unknown } | null;
  const identifier = (input: unknown) => typeof input === "string" && /^[A-Za-z0-9_]{1,80}$/.test(input) ? input : "unknown";
  console.error("License service unavailable", { operation, name: identifier(value?.name), code: identifier(value?.code) });
}
