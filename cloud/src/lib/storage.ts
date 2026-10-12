import fs from "node:fs/promises";
import path from "node:path";
import { profileAppType } from "./app-registry";

/**
 * Storage abstraction for Jew Automations / RedditBox cloud.
 *
 * Two adapters with identical APIs:
 *  - Vercel Blob (production, when BLOB_READ_WRITE_TOKEN is set)
 *  - Local filesystem (development / self-host: JSON collections under
 *    cloud/.data/, blob bytes as .bin files)
 *
 * Privacy: collection JSON (users, licenses, pairing codes, …) and backup
 * bytes are never handed to browsers as Blob URLs. The Vercel adapter
 * defaults to `access: "private"` and reads through the authenticated SDK
 * (`get()`), not public CDN URLs. Access never auto-downgrades: a legacy
 * public store must be selected explicitly with BLOB_ACCESS=public.
 *
 * Concurrency (Vercel Blob):
 *  - mutateCollection takes a short-lived lock object, then writes the
 *    collection with `ifMatch` (ETag) so a stale overwrite fails and retries.
 *  - Creation uses allowOverwrite:false; an existing object requires its ETag.
 *  - Authentication collections share one document so claims, entitlements,
 *    and revocations have one commit point.
 *  - Local writers also take a cross-process lock. An abandoned lock fails
 *    closed rather than being stolen from a possibly paused writer.
 */

export type Role = "user" | "admin";

export interface UserRecord {
  id: string;
  email: string; // lowercased; username logins map to user@redditbox.local
  /** Optional login handle (e.g. typekpaco). Email local-part is the fallback. */
  username?: string;
  passwordHash: string; // bcrypt
  role: Role;
  /** ISO timestamp when a license was activated for this user */
  licensedAt: string | null;
  createdAt: string;
}

export type DeviceRole = "factory" | "worker";

export interface DeviceRecord {
  id: string;
  userId: string;
  name: string;
  role: DeviceRole;
  /** sha256 hex of the device token; null until the phone claims the pairing code */
  tokenHash: string | null;
  pairedAt: string;
  lastSeenAt: string;
  /** Installation UUID digest; immutable after first device-license claim. */
  deviceBinding?: string;
  licenseId?: string | null;
  licenseStatus?: "active" | "revoked" | "expired" | "invalid";
}

export interface LicenseRecord {
  id: string;
  /** bcrypt hash of the license key; the plaintext key is shown only once at generation */
  keyHash: string;
  /** sha256 hex of the normalized key for O(1) device validation lookups */
  keyFingerprint?: string;
  createdAt: string;
  /** email of the user who activated it, once activated */
  activatedBy: string | null;
  activatedAt: string | null;
  /** ISO timestamp when an admin revoked this access key */
  revokedAt?: string | null;
  /** Optional expiry; null/absent means no expiry */
  expiresAt?: string | null;
  /** Last successful device validation */
  lastValidatedAt?: string | null;
  kind?: "device";
  ownerUserId?: string;
  maxActivations?: number;
  label?: string;
  note?: string;
  deletedAt?: string | null;
  activations?: { deviceId: string; deviceBinding: string; activatedAt: string; lastCheckedAt: string | null }[];
}

export interface DeviceLicenseEvent {
  id: string; at: string; action: string; licenseId: string | null;
  deviceId?: string; actorUserId?: string; detail?: string;
}
export interface DeviceLicensingState {
  version: 1; migratedAt: string;
  /** Frozen migration snapshot; later pairings never gain this entitlement. */
  adminDevices: { deviceId: string; userId: string }[];
  rates: { binding: string; kind: "claim" | "validate"; windowStart: number; count: number }[];
  events: DeviceLicenseEvent[];
}

export interface LicenseAuditRecord {
  id: string;
  at: string;
  action: "grant" | "revoke";
  actorUserId: string;
  actorUsername: string;
  /** Full license id (internal). UI shows keyIdPrefix only. */
  licenseId: string;
  /** First 8 chars of license id — never the plaintext key */
  keyIdPrefix: string;
  expiresAt?: string | null;
}

export interface BackupRecord {
  chunks?: import("./backup-transfer").BackupPart[];
  /** Incomplete encrypted transfer; never listed or downloadable as a backup. */
  upload?: import("./backup-transfer").BackupUpload;
  /** Captured server-side at upload. Absent legacy records remain origin-device-only. */
  licenseId?: string | null;
  appType?: string;
  name?: string;
  id: string; // random 16-hex, also returned as backupId
  deviceId: string;
  userId: string;
  containerId: string;
  size: number;
  createdAt: string;
  /** base64 IV / nonce (12 bytes). Server never decrypts. */
  iv: string;
  /** base64 PBKDF2 salt (16 bytes). */
  salt: string;
  /** sha256 hex of the ciphertext bytes (integrity only). */
  checksum: string;
  attestKeyUsed?: boolean;
  /** JSON string of the AAD header if a legacy raw-blob upload included one */
  aad?: string;
  /** adapter-specific location: local path or Blob pathname (never a public URL) */
  blobPath: string;
}

export interface PairingCodeRecord {
  id: string;
  code: string; // 8 chars from the unambiguous charset
  userId: string;
  /** pending device created at pair time; claim fills its token */
  deviceId: string;
  createdAt: string;
  expiresAt: string;
  /** consumedAt set once a device claimed it */
  consumedAt: string | null;
  consumedByDeviceId: string | null;
}

export type ProxyType = "http" | "https" | "socks5";
export type ProxyHealthStatus = "unknown" | "healthy" | "unhealthy";

export interface ProxyRecord {
  id: string;
  userId: string;
  name: string;
  type: ProxyType;
  host: string;
  port: number;
  username: string | null;
  /** Secret; server responses must use hasPassword/maskedPassword instead. */
  password: string | null;
  healthStatus: ProxyHealthStatus;
  lastCheckedAt: string | null;
  latencyMs: number | null;
  healthMessage: string | null;
  /** Atomic source of truth for one-to-one assignment. */
  assignedProfileId?: string | null;
  assignedAt?: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface ProfileProxyAssignment {
  id: string;
  userId: string;
  profileId: string;
  proxyId: string;
  assignedAt: string;
  updatedAt: string;
}

export interface ProfileRecord {
  /** Immutable registered app identity; missing legacy rows migrate to reddit. */
  appType?: string;
  id: string;
  userId: string;
  deviceId: string;
  profileId: string;
  lastSeenAt: string;
  /** Optional console-created profile metadata consumed by the device launcher. */
  nickname?: string | null;
  country?: string | null;
  /** Informational metadata; never used for network or identity policy. */
  role?: import("./profile-metadata").ProfileRole;
  notes?: string;
  metadataRevision?: number;
  createdAt?: string | null;
  /** Per-profile rotation API header override; secret is AES-GCM encrypted. */
  rotationAuthHeader?: string | null;
  rotationAuthSecretEnc?: string | null;
}

export interface RotationSettingsRecord {
  /** Explicit owner authorization; absent legacy records are not delivered to devices. */
  deviceAccess?: "all-paired";
  id: string;
  userId: string;
  proxyURLSecretEnc: string;
  rotationURL: string;
  authHeader: string;
  authorizationSecretEnc: string | null;
  method: "GET" | "POST";
  updatedAt: string;
}

export type CollectionName =
  | "socialbox-releases"
  | "inventory-state"
  | "profile-tombstones"
  | "auth-state"
  | "users"
  | "devices"
  | "licenses"
  | "backups"
  | "pairing-codes"
  | "license-audit"
  | "proxies"
  | "profiles"
  | "rotation-settings"
  | "profile-proxy-assignments";

interface CollectionDoc<T> {
  version: number;
  items: T[];
  exists?: boolean;
}

export interface BlobMetadata {
  id: string;
  size: number;
  contentType: string;
  uploadedAt: string;
}

// ---------------------------------------------------------------------------
// Adapter interface
// ---------------------------------------------------------------------------

interface CollectionAdapter {
  readonly kind: "local" | "vercel-blob";

  readCollection<T>(name: CollectionName): Promise<T[]>;
  readCollectionSnapshot<T>(name: CollectionName): Promise<{ items: T[]; exists: boolean }>;
  writeCollection<T>(name: CollectionName, items: T[]): Promise<void>;
  /** Atomically mutate a collection. Retry-safe: fn receives current items. */
  mutateCollection<T>(name: CollectionName, fn: (items: T[], exists: boolean) => T[]): Promise<T[]>;

  putBlob(key: string, data: Uint8Array): Promise<string>;
  getBlob(key: string): Promise<Uint8Array | null>;
  deleteBlob(key: string): Promise<void>;
}

export interface AuthState {
  users: UserRecord[];
  devices: DeviceRecord[];
  licenses: LicenseRecord[];
  "pairing-codes": PairingCodeRecord[];
  deviceLicensing?: DeviceLicensingState;
}

export interface ProfileTombstone {
  id: string;
  userId: string;
  deviceId: string;
  profileId: string;
  deletedAt: string;
}
export interface InventoryState {
  profiles: ProfileRecord[];
  proxies: ProxyRecord[];
  "profile-tombstones": ProfileTombstone[];
}

export interface StorageAdapter extends Omit<CollectionAdapter, "readCollectionSnapshot"> {
  readAuthState(): Promise<AuthState>;
  /** One commit for all authentication records. fn may run again after a CAS conflict. */
  mutateAuthState(fn: (state: AuthState) => AuthState): Promise<AuthState>;
  readInventoryState(): Promise<InventoryState>;
  mutateInventoryState(fn: (state: InventoryState) => InventoryState): Promise<InventoryState>;
}

export function usingVercelBlob(): boolean {
  return !!process.env.BLOB_READ_WRITE_TOKEN;
}

export type BlobAccessMode = "public" | "private";

/** Default private. Set BLOB_ACCESS=public only for a legacy public store. */
export function configuredBlobAccess(): BlobAccessMode {
  return process.env.BLOB_ACCESS === "public" ? "public" : "private";
}

// ---------------------------------------------------------------------------
// Local adapter
// ---------------------------------------------------------------------------

const DATA_DIR = path.join(process.cwd(), ".data");

function collectionFile(name: CollectionName): string {
  return path.join(DATA_DIR, `${name}.json`);
}

async function ensureDataDir(): Promise<void> {
  await fs.mkdir(DATA_DIR, { recursive: true });
}

async function readCollectionDoc<T>(name: CollectionName): Promise<CollectionDoc<T>> {
  await ensureDataDir();
  try {
    const raw = await fs.readFile(collectionFile(name), "utf8");
    const doc = JSON.parse(raw) as CollectionDoc<T>;
    if (!Array.isArray(doc.items) || typeof doc.version !== "number") {
      throw new Error(`Corrupt collection doc: ${name}`);
    }
    return { ...doc, exists: true };
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") {
      return { version: 0, items: [], exists: false };
    }
    throw err;
  }
}

let localMutationTail: Promise<void> = Promise.resolve();

async function withLocalMutationLock<T>(operation: () => Promise<T>): Promise<T> {
  const previous = localMutationTail;
  let release!: () => void;
  localMutationTail = new Promise<void>((resolve) => {
    release = resolve;
  });
  await previous;
  const lockDirectory = path.join(DATA_DIR, ".mutation-lock");
  let acquired = false;
  try {
    await ensureDataDir();
    const deadline = Date.now() + 15_000;
    while (!acquired) {
      try {
        await fs.mkdir(lockDirectory, { mode: 0o700 });
        acquired = true;
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
        if (Date.now() >= deadline) {
          throw new Error("Local store lock is busy or interrupted. Stop all server instances before removing an abandoned .mutation-lock directory.");
        }
        await new Promise((resolve) => setTimeout(resolve, 25 + Math.random() * 50));
      }
    }
    return await operation();
  } finally {
    // No recursive deletion or age-based lock stealing. A dead process leaves
    // this directory in place; operators must stop writers before removing it.
    if (acquired) await fs.rmdir(lockDirectory).catch(() => {
      // The commit may have succeeded. Do not hide its token behind a cleanup
      // error; this retained lock safely prevents subsequent writes.
      console.error("Local store lock cleanup failed; stop all server instances before repairing .mutation-lock.");
    });
    release();
  }
}

class LocalAdapter implements CollectionAdapter {
  readonly kind = "local" as const;

  async readCollection<T>(name: CollectionName): Promise<T[]> {
    const doc = await readCollectionDoc<T>(name);
    return doc.items;
  }

  async readCollectionSnapshot<T>(name: CollectionName): Promise<{ items: T[]; exists: boolean }> {
    const doc = await readCollectionDoc<T>(name);
    return { items: doc.items, exists: doc.exists === true };
  }

  async writeCollection<T>(name: CollectionName, items: T[]): Promise<void> {
    await this.mutateCollection(name, () => items);
  }

  async mutateCollection<T>(name: CollectionName, fn: (items: T[], exists: boolean) => T[]): Promise<T[]> {
    return withLocalMutationLock(async () => {
      const before = await readCollectionDoc<T>(name);
      const nextItems = fn([...before.items], before.exists === true);
      const next: CollectionDoc<T> = { version: before.version + 1, items: nextItems };
      const file = collectionFile(name);
      const tmp = `${file}.tmp-${Date.now()}-${Math.random().toString(36).slice(2)}`;
      try {
        const handle = await fs.open(tmp, "wx", 0o600);
        try {
          await handle.writeFile(JSON.stringify(next, null, 2), "utf8");
          await handle.sync();
        } finally {
          await handle.close();
        }
        for (let attempt = 0; ; attempt++) {
          try {
            await fs.rename(tmp, file);
            break;
          } catch (error) {
            const code = (error as NodeJS.ErrnoException).code;
            if (process.platform !== "win32" || attempt >= 7 ||
                !["EPERM", "EACCES", "EBUSY"].includes(code ?? "")) throw error;
            // A Windows reader may briefly hold a non-delete-shared handle.
            // Retrying rename is safe; truncating the live document is not.
            await new Promise((resolve) => setTimeout(resolve, 15 * (attempt + 1)));
          }
        }
        if (process.platform !== "win32") {
          let directory: Awaited<ReturnType<typeof fs.open>> | undefined;
          try {
            directory = await fs.open(DATA_DIR, "r");
            await directory.sync();
          } catch {
            // Rename has committed. Do not encourage a second, different claim
            // after an uncertain durability outcome.
            console.error("Local store committed, but directory durability could not be confirmed.");
          } finally {
            await directory?.close().catch(() => {});
          }
        }
        return nextItems;
      } catch (err) {
        await fs.unlink(tmp).catch(() => {});
        throw err;
      }
    });
  }

  async putBlob(key: string, data: Uint8Array): Promise<string> {
    await ensureDataDir();
    const file = path.join(DATA_DIR, `${key}.bin`);
    await fs.writeFile(file, data);
    return file;
  }

  async getBlob(key: string): Promise<Uint8Array | null> {
    try {
      const buf = await fs.readFile(path.join(DATA_DIR, `${key}.bin`));
      return new Uint8Array(buf);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") return null;
      throw err;
    }
  }

  async deleteBlob(key: string): Promise<void> {
    await fs.unlink(path.join(DATA_DIR, `${key}.bin`)).catch((err) => {
      if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
    });
  }
}

// ---------------------------------------------------------------------------
// Vercel Blob adapter
// ---------------------------------------------------------------------------

type BlobAccess = "public" | "private";

function isBlobMissing(err: unknown): boolean {
  const name = err && typeof err === "object" && "name" in err ? String((err as { name: string }).name) : "";
  if (name === "BlobNotFoundError") return true;
  const message = err instanceof Error ? err.message : String(err);
  return /does not exist|BlobNotFound|404/i.test(message);
}

function isPreconditionFailed(err: unknown): boolean {
  const name = err && typeof err === "object" && "name" in err ? String((err as { name: string }).name) : "";
  if (name === "BlobPreconditionFailedError") return true;
  const message = err instanceof Error ? err.message : String(err);
  return /precondition|if-match|ifMatch|412/i.test(message);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function streamToBytes(stream: ReadableStream<Uint8Array>): Promise<Uint8Array> {
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

class VercelBlobAdapter implements CollectionAdapter {
  readonly kind = "vercel-blob" as const;
  private readonly access: BlobAccess = configuredBlobAccess();

  private docKey(name: CollectionName): string {
    return `collections/${name}.json`;
  }

  private lockKey(name: CollectionName): string {
    return `locks/${name}.lock`;
  }

  private backupKey(key: string): string {
    return `backups/${key}.bin`;
  }

  async readCollection<T>(name: CollectionName): Promise<T[]> {
    const { doc } = await this.readDoc<T>(name);
    return doc.items ?? [];
  }

  async readCollectionSnapshot<T>(name: CollectionName): Promise<{ items: T[]; exists: boolean }> {
    const { doc, etag } = await this.readDoc<T>(name);
    return { items: doc.items, exists: etag !== null };
  }

  private async readDoc<T>(
    name: CollectionName
  ): Promise<{ doc: CollectionDoc<T>; etag: string | null }> {
    const empty: CollectionDoc<T> = { version: 0, items: [] };
    try {
      const got = await this.getAuthenticated(this.docKey(name));
      if (!got) return { doc: empty, etag: null };
      const parsed = JSON.parse(new TextDecoder().decode(got.bytes)) as CollectionDoc<T>;
      if (!Array.isArray(parsed.items)) {
        throw new Error(`Corrupt collection doc: ${name}`);
      }
      return { doc: parsed, etag: got.etag };
    } catch (err: unknown) {
      if (isBlobMissing(err)) return { doc: empty, etag: null };
      throw err;
    }
  }

  /** Server-only read via the Blob SDK. Never returns a public URL. */
  private async getAuthenticated(
    pathname: string
  ): Promise<{ bytes: Uint8Array; etag: string } | null> {
    const { get } = await import("@vercel/blob");
    try {
      // Compression can turn the object's strong ETag into W/"...". Blob
      // rejects that weak validator in ifMatch, so every transaction then
      // exhausts its retries. Request the original representation instead.
      const result = await get(pathname, { access: this.access, useCache: false,
        headers: { "Accept-Encoding": "identity" } });
      if (!result) return null;
      if (result.statusCode !== 200 || !result.stream) throw new Error("Unexpected Blob collection response");
      if (!result.blob.etag || result.blob.etag.startsWith("W/"))
        throw new Error("Blob collection requires a strong ETag; state was not modified");
      return { bytes: await streamToBytes(result.stream), etag: result.blob.etag };
    } catch (err: unknown) {
      if (isBlobMissing(err)) return null;
      if (this.access === "private") throw err;
    }

    // Explicit legacy-public mode: head() + server-side fetch. The URL remains server-only.
    try {
      const { head } = await import("@vercel/blob");
      const meta = await head(pathname);
      if (!meta?.url) return null;
      const res = await fetch(`${meta.url}?v=${Date.now()}`, { cache: "no-store" });
      if (res.status === 404) return null;
      if (!res.ok) {
        throw new Error(`Failed to fetch blob ${pathname}: ${res.status}`);
      }
      const fetchedETag = res.headers.get("etag");
      if (!fetchedETag || fetchedETag.startsWith("W/") ||
          !(fetchedETag === meta.etag || fetchedETag === `"${meta.etag}"`)) {
        throw new Error("Legacy Blob body could not be bound to its current ETag");
      }
      return { bytes: new Uint8Array(await res.arrayBuffer()), etag: meta.etag };
    } catch (err: unknown) {
      if (isBlobMissing(err)) return null;
      throw err;
    }
  }

  private async putObject(
    pathname: string,
    body: string | Blob,
    extra: { contentType?: string; ifMatch?: string; allowOverwrite?: boolean } = {}
  ): Promise<void> {
    const { put } = await import("@vercel/blob");
    const options = {
      access: this.access,
      addRandomSuffix: false,
      allowOverwrite: extra.allowOverwrite ?? true,
      cacheControlMaxAge: 0,
      contentType: extra.contentType,
      ifMatch: extra.ifMatch,
    };

    await put(pathname, body, options);
  }

  /**
   * Best-effort exclusive lock. Residual: a crash can leave a lock until
   * LOCK_STALE_MS elapses; two stealers can both delete a stale lock.
   * Collection writes still use ifMatch so a lost race does not clobber.
   */
  private async withLock<T>(name: CollectionName, fn: () => Promise<T>): Promise<T> {
    const { put, del, head } = await import("@vercel/blob");
    const lockPath = this.lockKey(name);
    const LOCK_STALE_MS = 20_000;

    for (let attempt = 0; attempt < 8; attempt++) {
      let acquired = false;
      try {
        await put(lockPath, String(Date.now()), {
          access: this.access,
          addRandomSuffix: false,
          allowOverwrite: false,
          cacheControlMaxAge: 0,
          contentType: "text/plain",
        });
        acquired = true;
      } catch (err: unknown) {
        try {
          const meta = await head(lockPath);
          if (Date.now() - meta.uploadedAt.getTime() > LOCK_STALE_MS) {
            await del(lockPath).catch(() => {});
            continue;
          }
        } catch {
          // lock vanished or never existed; retry acquire
        }
        await sleep(40 + Math.random() * 80 * (attempt + 1));
      }
      if (acquired) {
        try {
          return await fn();
        } finally {
          await del(lockPath).catch(() => {});
        }
      }
    }
    throw new Error(`Could not acquire collection lock ${name}`);
  }

  async writeCollection<T>(name: CollectionName, items: T[]): Promise<void> {
    await this.mutateCollection(name, () => items);
  }

  async mutateCollection<T>(name: CollectionName, fn: (items: T[], exists: boolean) => T[]): Promise<T[]> {
    return this.withLock(name, async () => {
      for (let attempt = 0; attempt < 5; attempt++) {
        const { doc, etag } = await this.readDoc<T>(name);
        const nextItems = fn([...(doc.items ?? [])], etag !== null);
        const payload = JSON.stringify({ version: (doc.version ?? 0) + 1, items: nextItems });
        try {
          await this.putObject(this.docKey(name), payload, {
            contentType: "application/json",
            ifMatch: etag ?? undefined,
            allowOverwrite: Boolean(etag),
          });
          return nextItems;
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : String(err);
          const retryable =
            isPreconditionFailed(err) || /already exists|overwrite|conflict/i.test(message);
          if (retryable) {
            await sleep(30 + Math.random() * 50);
            continue;
          }
          throw err;
        }
      }
      throw new Error(`Concurrent write conflict on collection ${name}; retries exhausted`);
    });
  }

  async putBlob(key: string, data: Uint8Array): Promise<string> {
    const pathname = this.backupKey(key);
    const body = new Blob([new Uint8Array(data)], {
      type: "application/octet-stream",
    });
    await this.putObject(pathname, body, {
      contentType: "application/octet-stream",
      allowOverwrite: true,
    });
    return pathname;
  }

  async getBlob(key: string): Promise<Uint8Array | null> {
    try {
      const got = await this.getAuthenticated(this.backupKey(key));
      return got?.bytes ?? null;
    } catch (err: unknown) {
      if (isBlobMissing(err)) return null;
      throw err;
    }
  }

  async deleteBlob(key: string): Promise<void> {
    const { del } = await import("@vercel/blob");
    await del(this.backupKey(key));
  }
}

// ---------------------------------------------------------------------------
// Singleton access
// ---------------------------------------------------------------------------

const AUTH_COLLECTIONS = ["users", "devices", "licenses", "pairing-codes"] as const;
type AuthCollectionName = typeof AUTH_COLLECTIONS[number];
interface AuthStateRecord extends AuthState {
  id: "auth-state";
  formatVersion: 1;
}

function isAuthCollection(name: CollectionName): name is AuthCollectionName {
  return (AUTH_COLLECTIONS as readonly string[]).includes(name);
}

function checkedAuthState(records: AuthStateRecord[]): AuthStateRecord {
  const state = records[0];
  if (records.length !== 1 || !state || state.id !== "auth-state" ||
      state.formatVersion !== 1 || AUTH_COLLECTIONS.some((name) => !Array.isArray(state[name]))) {
    throw new Error("Corrupt authentication state; legacy collections were not reactivated");
  }
  if (state.deviceLicensing && (state.deviceLicensing.version !== 1 ||
      !Array.isArray(state.deviceLicensing.adminDevices) || !Array.isArray(state.deviceLicensing.rates) ||
      !Array.isArray(state.deviceLicensing.events)))
    throw new Error("Unsupported or corrupt device licensing migration; authentication state preserved");
  if (state.deviceLicensing) {
    const licensing = state.deviceLicensing;
    if (!Number.isFinite(Date.parse(licensing.migratedAt)) ||
        licensing.adminDevices.some((entry) => !entry || typeof entry.deviceId !== "string" || !entry.deviceId || typeof entry.userId !== "string" || !entry.userId) ||
        licensing.rates.some((entry) => !entry || typeof entry.binding !== "string" || !/^[0-9a-f]{64}$/.test(entry.binding) ||
          !["claim", "validate"].includes(entry.kind) || !Number.isSafeInteger(entry.windowStart) || entry.windowStart < 0 ||
          !Number.isSafeInteger(entry.count) || entry.count < 0) ||
        licensing.events.some((entry) => !entry || typeof entry.id !== "string" || !entry.id ||
          !Number.isFinite(Date.parse(entry.at)) || typeof entry.action !== "string" ||
          (entry.licenseId !== null && typeof entry.licenseId !== "string")))
      throw new Error("Corrupt device licensing migration, rate limits or history; authentication state preserved");
  }
  return state;
}

function migrateDeviceLicensing(state: AuthStateRecord): AuthStateRecord {
  if (state.deviceLicensing) return state;
  const admins = new Set(state.users.filter((user) => user.role === "admin").map((user) => user.id));
  return { ...state, deviceLicensing: { version: 1, migratedAt: new Date().toISOString(),
    adminDevices: state.devices.filter((device) => Boolean(device.tokenHash) && admins.has(device.userId))
      .map(({ id: deviceId, userId }) => ({ deviceId, userId })), rates: [], events: [] } };
}

/**
 * Keep the public collection interface while assigning these related records
 * one commit point. Legacy files remain untouched as migration backups; once
 * auth-state exists they are never consulted again. Stop old-version writers
 * during deployment, since they do not know this document is authoritative.
 */
const INVENTORY_COLLECTIONS = ["profiles", "proxies", "profile-tombstones"] as const;
type InventoryCollectionName = typeof INVENTORY_COLLECTIONS[number];
interface InventoryStateRecord extends InventoryState {
  id: "inventory-state"; formatVersion: 1;
  legacyAssignmentMigration?: { version: 1; migratedAt: string; ignoredRetired: number };
}
function isInventoryCollection(name: CollectionName): name is InventoryCollectionName {
  return (INVENTORY_COLLECTIONS as readonly string[]).includes(name);
}
function checkedInventory(records: InventoryStateRecord[]): InventoryStateRecord {
  const state = records[0];
  if (records.length !== 1 || !state || state.id !== "inventory-state" || state.formatVersion !== 1 ||
      INVENTORY_COLLECTIONS.some((name) => !Array.isArray(state[name])))
    throw new Error("Corrupt inventory transaction state; legacy records were not reactivated");
  for (const records of [state.profiles, state["profile-tombstones"]]) {
    const seen = new Set<string>();
    for (const item of records) {
      if (!item || typeof item.userId !== "string" || !item.userId ||
          typeof item.deviceId !== "string" || !item.deviceId ||
          typeof item.profileId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(item.profileId))
        throw new Error("Invalid legacy profile identifier/binding; repair explicitly before migration");
      const key = JSON.stringify([item.userId, item.profileId.toLowerCase()]);
      if (seen.has(key)) throw new Error("Ambiguous case-insensitive profile identifiers");
      seen.add(key);
    }
  }
  if (state["profile-tombstones"].some((item) => typeof item.id !== "string" || !item.id ||
      typeof item.deletedAt !== "string" || !Number.isFinite(Date.parse(item.deletedAt))))
    throw new Error("Invalid profile retirement receipt");
  if (state.proxies.some((item) => item.assignedProfileId != null &&
      (typeof item.assignedProfileId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(item.assignedProfileId))))
    throw new Error("Invalid proxy profile identifier; repair explicitly before migration");
  const retired = new Set(state["profile-tombstones"].map((item) => JSON.stringify([item.userId, item.profileId.toLowerCase()])));
  if (state.profiles.some((item) => retired.has(JSON.stringify([item.userId, item.profileId.toLowerCase()]))) ||
      state.proxies.some((item) => item.assignedProfileId && retired.has(JSON.stringify([item.userId, item.assignedProfileId.toLowerCase()]))))
    throw new Error("PROFILE_RETIRED");
  // Additive lazy schema migration: reads expose an explicit type, and the
  // next existing CAS mutation persists it. Read-only access never rewrites the
  // stored document, source data, licenses, or legacy migration backups.
  return { ...state, profiles: state.profiles.map((profile) =>
    ({ ...profile, appType: profileAppType(profile) })) };
}

export class InventoryMigrationError extends Error {}

function migrateLegacyAssignments(current: InventoryStateRecord, legacy: ProfileProxyAssignment[]): InventoryStateRecord {
  if (current.legacyAssignmentMigration) {
    if (current.legacyAssignmentMigration.version !== 1) throw new Error("Unsupported assignment migration version");
    return current;
  }
  const next = structuredClone(current);
  const key = (owner: string, value: string) => JSON.stringify([owner, value]);
  const profiles = new Set(next.profiles.map((item) => key(item.userId, item.profileId)));
  const retired = new Set(next["profile-tombstones"].map((item) => key(item.userId, item.profileId.toLowerCase())));
  const proxies = new Map<string, ProxyRecord>();
  const claimed = new Map<string, string>();
  const fail = (reason: string): never => { throw new InventoryMigrationError(`Legacy assignment migration blocked: ${reason}; records preserved for explicit repair`); };
  for (const proxy of next.proxies) {
    const proxyKey = key(proxy.userId, proxy.id);
    if (proxies.has(proxyKey)) fail("duplicate proxy identifier");
    proxies.set(proxyKey, proxy);
    if (!proxy.assignedProfileId) continue;
    const profileKey = key(proxy.userId, proxy.assignedProfileId);
    if (!profiles.has(profileKey)) fail("current assignment references a missing or ambiguous live profile");
    if (claimed.has(profileKey)) fail("multiple current proxies claim the same profile");
    claimed.set(profileKey, proxy.id);
  }
  let ignoredRetired = 0;
  for (const assignment of legacy) {
    if (!assignment || typeof assignment.userId !== "string" || !assignment.userId ||
        typeof assignment.proxyId !== "string" || !assignment.proxyId ||
        typeof assignment.profileId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(assignment.profileId))
      fail("invalid owner/profile/proxy identifier");
    if (retired.has(key(assignment.userId, assignment.profileId.toLowerCase()))) { ignoredRetired++; continue; }
    const profileKey = key(assignment.userId, assignment.profileId);
    if (!profiles.has(profileKey)) fail("legacy assignment has no registered live profile");
    const proxy = proxies.get(key(assignment.userId, assignment.proxyId));
    if (!proxy) fail("legacy assignment references an absent or other-owner proxy");
    if ((proxy!.assignedProfileId && proxy!.assignedProfileId !== assignment.profileId) ||
        (claimed.has(profileKey) && claimed.get(profileKey) !== assignment.proxyId))
      fail("conflicting one-to-one assignments");
    if (!proxy!.assignedProfileId) {
      proxy!.assignedProfileId = assignment.profileId;
      proxy!.assignedAt = assignment.assignedAt || assignment.updatedAt || proxy!.updatedAt;
    }
    claimed.set(profileKey, assignment.proxyId);
  }
  next.legacyAssignmentMigration = { version: 1, migratedAt: new Date().toISOString(), ignoredRetired };
  return checkedInventory([next]);
}

class AuthStateAdapter implements StorageAdapter {
  constructor(private readonly backend: CollectionAdapter) {}

  get kind(): "local" | "vercel-blob" { return this.backend.kind; }

  private async currentState(): Promise<AuthStateRecord> {
    const existing = await this.backend.readCollectionSnapshot<AuthStateRecord>("auth-state");
    if (existing.exists) {
      const current = checkedAuthState(existing.items);
      if (current.deviceLicensing) return current;
      const migrated = await this.backend.mutateCollection<AuthStateRecord>("auth-state", (records) =>
        [migrateDeviceLicensing(checkedAuthState(records))]);
      return checkedAuthState(migrated);
    }
    const [users, devices, licenses, pairingCodes] = await Promise.all([
      this.backend.readCollection<UserRecord>("users"),
      this.backend.readCollection<DeviceRecord>("devices"),
      this.backend.readCollection<LicenseRecord>("licenses"),
      this.backend.readCollection<PairingCodeRecord>("pairing-codes"),
    ]);
    const seed: AuthStateRecord = {
      id: "auth-state", formatVersion: 1, users, devices, licenses, "pairing-codes": pairingCodes,
    };
    const migrated = await this.backend.mutateCollection<AuthStateRecord>("auth-state", (records, exists) => {
      // Another process may have migrated and already changed state while this
      // caller read the legacy files. Its current state always wins.
      if (exists) return [migrateDeviceLicensing(checkedAuthState(records))];
      return [migrateDeviceLicensing(seed)];
    });
    return checkedAuthState(migrated);
  }

  async mutateAuthState(fn: (state: AuthState) => AuthState): Promise<AuthState> {
    await this.currentState();
    const committed = await this.backend.mutateCollection<AuthStateRecord>("auth-state", (records) => {
      const current = checkedAuthState(records);
      const next = fn(structuredClone(current));
      if (!next || AUTH_COLLECTIONS.some((name) => !Array.isArray(next[name]))) {
        throw new Error("Invalid authentication transaction result");
      }
      return [checkedAuthState([{ ...next, deviceLicensing: next.deviceLicensing ?? current.deviceLicensing,
        id: "auth-state", formatVersion: 1 }])];
    });
    return checkedAuthState(committed);
  }

  async readAuthState(): Promise<AuthState> { return this.currentState(); }

  async readInventoryState(): Promise<InventoryState> {
    const existing = await this.backend.readCollectionSnapshot<InventoryStateRecord>("inventory-state");
    const observed = existing.exists ? checkedInventory(existing.items) : null;
    if (observed?.legacyAssignmentMigration) {
      if (observed.legacyAssignmentMigration.version !== 1) throw new Error("Unsupported assignment migration version");
      return observed;
    }
    // Deployment must stop old writers. Legacy files stay untouched; migration
    // and its completion marker share the inventory document's single CAS.
    const [profiles, proxies, legacy] = await Promise.all([
      observed ? Promise.resolve(observed.profiles) : this.backend.readCollection<ProfileRecord>("profiles"),
      observed ? Promise.resolve(observed.proxies) : this.backend.readCollection<ProxyRecord>("proxies"),
      this.backend.readCollection<ProfileProxyAssignment>("profile-proxy-assignments"),
    ]);
    const seed: InventoryStateRecord = { id: "inventory-state", formatVersion: 1,
      profiles, proxies, "profile-tombstones": [] };
    const migrated = await this.backend.mutateCollection<InventoryStateRecord>("inventory-state", (records, exists) => {
      const current = exists ? checkedInventory(records) : checkedInventory([seed]);
      return [migrateLegacyAssignments(current, legacy)];
    });
    return checkedInventory(migrated);
  }
  async mutateInventoryState(fn: (state: InventoryState) => InventoryState): Promise<InventoryState> {
    await this.readInventoryState();
    const committed = await this.backend.mutateCollection<InventoryStateRecord>("inventory-state", (records) => {
      const current = checkedInventory(records);
      const next = checkedInventory([{ ...fn(structuredClone(current)), id: "inventory-state", formatVersion: 1,
        legacyAssignmentMigration: current.legacyAssignmentMigration }]);
      // A generic profile/proxy writer cannot bypass retirement, including one
      // that read a profile or backup before a concurrent deletion committed.
      // App identity is permanent even for generic collection writers. IDs and
      // retirement remain globally unique per owner, not scoped by appType.
      for (const profile of current.profiles) {
        const replacement = next.profiles.find((item) => item.userId === profile.userId &&
          item.profileId.toLowerCase() === profile.profileId.toLowerCase());
        if (replacement && replacement.appType !== profile.appType)
          throw new Error("Profile appType cannot be changed");
      }
      const remaining = new Set(next["profile-tombstones"].map((item) => JSON.stringify([item.id, item.userId, item.deviceId, item.profileId, item.deletedAt])));
      if (current["profile-tombstones"].some((item) => !remaining.has(JSON.stringify([item.id, item.userId, item.deviceId, item.profileId, item.deletedAt]))))
        throw new Error("Profile retirement cannot be undone by a collection update");
      return [next];
    });
    return checkedInventory(committed);
  }

  async readCollection<T>(name: CollectionName): Promise<T[]> {
    if (isInventoryCollection(name)) return (await this.readInventoryState())[name] as T[];
    if (isAuthCollection(name)) return (await this.currentState())[name] as T[];
    return this.backend.readCollection<T>(name);
  }

  async writeCollection<T>(name: CollectionName, items: T[]): Promise<void> {
    if (name === "profile-proxy-assignments") throw new Error("Legacy assignments are read-only; update the inventory proxy assignment");
    if (isInventoryCollection(name)) {
      await this.mutateInventoryState((state) => ({ ...state, [name]: items })); return;
    }
    if (name === "inventory-state") throw new Error("Use mutateInventoryState for inventory transactions");
    if (isAuthCollection(name)) {
      await this.mutateAuthState((state) => ({ ...state, [name]: items }));
      return;
    }
    if (name === "auth-state") throw new Error("Use mutateAuthState for authentication transactions");
    await this.backend.writeCollection(name, items);
  }

  async mutateCollection<T>(name: CollectionName, fn: (items: T[], exists: boolean) => T[]): Promise<T[]> {
    if (name === "profile-proxy-assignments") throw new Error("Legacy assignments are read-only; update the inventory proxy assignment");
    if (isInventoryCollection(name)) {
      const committed = await this.mutateInventoryState((state) => ({ ...state, [name]: fn(state[name] as T[], true) }));
      return committed[name] as T[];
    }
    if (name === "inventory-state") throw new Error("Use mutateInventoryState for inventory transactions");
    if (isAuthCollection(name)) {
      const committed = await this.mutateAuthState((state) => ({
        ...state, [name]: fn(state[name] as T[], true),
      }));
      return committed[name] as T[];
    }
    if (name === "auth-state") throw new Error("Use mutateAuthState for authentication transactions");
    return this.backend.mutateCollection(name, fn);
  }

  putBlob(key: string, data: Uint8Array): Promise<string> { return this.backend.putBlob(key, data); }
  getBlob(key: string): Promise<Uint8Array | null> { return this.backend.getBlob(key); }
  deleteBlob(key: string): Promise<void> { return this.backend.deleteBlob(key); }
}

let adapter: StorageAdapter | null = null;

export function getStorage(): StorageAdapter {
  if (!adapter) {
    adapter = new AuthStateAdapter(usingVercelBlob() ? new VercelBlobAdapter() : new LocalAdapter());
  }
  return adapter;
}

/** Test helper: drop the cached adapter so the next getStorage() rebuilds it. */
export function resetStorageAdapterForTests(): void {
  adapter = null;
}
