import type {
  ProfileProxyAssignment,
  ProxyHealthStatus,
  ProxyRecord,
  ProxyType,
} from "./storage";

const PROXY_TYPES = new Set<ProxyType>(["http"]);
const HEALTH_STATUSES = new Set<ProxyHealthStatus>(["unknown", "healthy", "unhealthy"]);
const HOST_RE =
  /^(?=.{1,253}$)(?:\[[0-9a-fA-F:]+\]|(?:[a-zA-Z0-9](?:[a-zA-Z0-9.-]{0,251}[a-zA-Z0-9])?)|(?:\d{1,3}\.){3}\d{1,3})$/;

export interface ProxyInput {
  name: string;
  type: ProxyType;
  host: string;
  port: number;
  username: string | null;
  password?: string | null;
}

export function parseProxyInput(
  value: unknown,
  options: { passwordOptional?: boolean } = {}
): { ok: true; value: ProxyInput } | { ok: false; error: string } {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { ok: false, error: "JSON object required" };
  }
  const body = value as Record<string, unknown>;
  const name = typeof body.name === "string" ? body.name.trim() : "";
  const type = typeof body.type === "string" ? body.type.toLowerCase() : "";
  const host = typeof body.host === "string" ? body.host.trim().toLowerCase() : "";
  const port =
    typeof body.port === "number"
      ? body.port
      : typeof body.port === "string" && body.port.trim()
        ? Number(body.port)
        : NaN;
  const username =
    typeof body.username === "string" && body.username.length ? body.username : null;
  const passwordPresent = Object.prototype.hasOwnProperty.call(body, "password");
  const password =
    typeof body.password === "string" && body.password.length ? body.password : null;

  if (!name || name.length > 80) return { ok: false, error: "name is required (max 80 chars)" };
  if (!PROXY_TYPES.has(type as ProxyType)) {
    return { ok: false, error: "Only HTTP proxies (including CONNECT for HTTPS sites) are supported" };
  }
  if (
    !host ||
    !HOST_RE.test(host) ||
    host.includes("://") ||
    host.includes("/") ||
    host.includes("@")
  ) {
    return { ok: false, error: "host must be a hostname or IP address without a URL scheme" };
  }
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return { ok: false, error: "port must be an integer from 1 to 65535" };
  }
  if (username && username.length > 256) {
    return { ok: false, error: "username is too long (max 256 chars)" };
  }
  if (password && password.length > 1024) {
    return { ok: false, error: "password is too long (max 1024 chars)" };
  }
  if ((username && /[\x00-\x1f\x7f:]/.test(username)) ||
      (password && /[\x00-\x1f\x7f]/.test(password))) {
    return { ok: false, error: "Proxy credentials contain unsupported control characters or a username colon" };
  }
  if (password && !username) {
    return { ok: false, error: "username is required when password is set" };
  }
  if (!passwordPresent && !options.passwordOptional) {
    return {
      ok: true,
      value: { name, type: type as ProxyType, host, port, username, password: null },
    };
  }
  return {
    ok: true,
    value: {
      name,
      type: type as ProxyType,
      host,
      port,
      username,
      ...(passwordPresent ? { password } : {}),
    },
  };
}

export function parseHealthFields(
  value: unknown
):
  | {
      ok: true;
      value: Partial<
        Pick<ProxyRecord, "healthStatus" | "lastCheckedAt" | "latencyMs" | "healthMessage">
      >;
    }
  | { ok: false; error: string } {
  const body = value as Record<string, unknown>;
  const result: Partial<
    Pick<ProxyRecord, "healthStatus" | "lastCheckedAt" | "latencyMs" | "healthMessage">
  > = {};
  if (Object.prototype.hasOwnProperty.call(body, "healthStatus")) {
    if (
      typeof body.healthStatus !== "string" ||
      !HEALTH_STATUSES.has(body.healthStatus as ProxyHealthStatus)
    ) {
      return { ok: false, error: "healthStatus must be unknown, healthy, or unhealthy" };
    }
    result.healthStatus = body.healthStatus as ProxyHealthStatus;
  }
  if (Object.prototype.hasOwnProperty.call(body, "lastCheckedAt")) {
    if (
      body.lastCheckedAt !== null &&
      (typeof body.lastCheckedAt !== "string" ||
        !Number.isFinite(Date.parse(body.lastCheckedAt)))
    ) {
      return { ok: false, error: "lastCheckedAt must be an ISO date or null" };
    }
    result.lastCheckedAt = body.lastCheckedAt as string | null;
  }
  if (Object.prototype.hasOwnProperty.call(body, "latencyMs")) {
    if (
      body.latencyMs !== null &&
      (typeof body.latencyMs !== "number" ||
        !Number.isFinite(body.latencyMs) ||
        body.latencyMs < 0)
    ) {
      return { ok: false, error: "latencyMs must be a non-negative number or null" };
    }
    result.latencyMs = body.latencyMs as number | null;
  }
  if (Object.prototype.hasOwnProperty.call(body, "healthMessage")) {
    if (
      body.healthMessage !== null &&
      (typeof body.healthMessage !== "string" || body.healthMessage.length > 500)
    ) {
      return { ok: false, error: "healthMessage must be at most 500 chars or null" };
    }
    result.healthMessage =
      typeof body.healthMessage === "string" ? body.healthMessage.trim() || null : null;
  }
  return { ok: true, value: result };
}

export function publicProxy(proxy: ProxyRecord) {
  const hasPassword = Boolean(proxy.password);
  return {
    id: proxy.id,
    name: proxy.name,
    type: proxy.type,
    host: proxy.host,
    port: proxy.port,
    username: proxy.username,
    hasPassword,
    maskedPassword: hasPassword ? "••••••••" : null,
    healthStatus: proxy.healthStatus,
    lastCheckedAt: proxy.lastCheckedAt,
    latencyMs: proxy.latencyMs,
    healthMessage: proxy.healthMessage,
    createdAt: proxy.createdAt,
    updatedAt: proxy.updatedAt,
  };
}

/** Device-authenticated payload only. Never return this from browser/user routes. */
export function deviceProxyUrl(proxy: ProxyRecord): string {
  const host = proxy.host.includes(":") && !proxy.host.startsWith("[")
    ? `[${proxy.host}]`
    : proxy.host;
  const credentials = proxy.username
    ? `${encodeURIComponent(proxy.username)}:${encodeURIComponent(proxy.password ?? "")}@`
    : "";
  return `${proxy.type}://${credentials}${host}:${proxy.port}`;
}

export function proxyEndpointKey(proxy: Pick<ProxyRecord, "type" | "host" | "port">): string {
  return `${proxy.type}://${proxy.host.toLowerCase()}:${proxy.port}`;
}

export class AssignmentConflict extends Error {}

/**
 * Assign without implicit rotation. Conflicting profile/proxy bindings require
 * the caller to opt into reassign, which removes only those exact conflicts.
 */
export function assignProxy(
  items: ProfileProxyAssignment[],
  next: ProfileProxyAssignment,
  reassign: boolean
): ProfileProxyAssignment[] {
  const owned = items.filter((item) => item.userId === next.userId);
  const same = owned.find(
    (item) => item.profileId === next.profileId && item.proxyId === next.proxyId
  );
  if (same) return items;

  const conflict = owned.some(
    (item) => item.profileId === next.profileId || item.proxyId === next.proxyId
  );
  if (conflict && !reassign) {
    throw new AssignmentConflict(
      "Profile or proxy is already assigned; retry with reassign=true to replace it explicitly"
    );
  }

  const kept = reassign
    ? items.filter(
        (item) =>
          item.userId !== next.userId ||
          (item.profileId !== next.profileId && item.proxyId !== next.proxyId)
      )
    : items;
  return [...kept, next];
}
