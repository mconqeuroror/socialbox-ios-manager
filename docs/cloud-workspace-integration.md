# Cloud workspace integration — 2026-09-17

The existing `redditspoof.vercel.app` account, licensing, private backup storage,
and public APT store remain the integration points. No replacement license or
signing keys were generated. Branch: `feat/socialbox-multiapp`, unmerged.
Reference interaction analysis is in `reference-workflows-2026-09.md`.

## Operator flow

Open Home → cloud icon, or Settings → Cloud and transfer. Cloud lists the selected
app's backups. Use +, search for a local container, select it and confirm the
backup. The existing quiescent snapshot closes protected sessions and preserves
the original container. Merely browsing or selecting never uploads or opens a clone.

On the destination phone, activate with the same existing license. On the source,
Cloud → Encryption key → Show / copy current key; enter that key on the destination
with Use key from another phone. Keep previous keys: replacing a phone's current
key does not re-encrypt older backups. Copy is explicit, local-only and expires
from the clipboard after one minute. Private key UI clears when backgrounded or
when its license/status publication expires.

Select a backup → Restore as new container → confirm. Existing local containers
are preserved. Decrypted manifest ownership must match the selected app before
any restore mutation. Existing transactional recovery, closed-network and
managed VPN requirements still apply. Facebook remains inactive pending its
separate device acceptance; this UI does not enable it.

Open web console goes to the configured HTTPS origin's `/apps/reddit#cloud-backups`
without credentials in the URL. The existing signed-in account can search/filter
its backups, copy an ID, and explicitly delete a backup. A failed delete keeps the
row and shows the server error. The web does not receive the encryption key.

## Authorization and private delivery

New backups capture the uploading profile's authoritative app/name, account,
origin device and current license ID. A different phone can list/download/delete
only if it belongs to the same account and has a currently valid activation of
that exact license. Revoked, expired, deleted or binding-mismatched grants fail.
Existing records without a captured license retain origin-device-only access;
access is never inferred from a subsequently changed device license. Existing
owner web sessions retain their account-level management access.

The launcher and daemon exchange backup metadata/key material in request-bound,
direction-bound Keychain records under their existing private access group.
Records expire after five minutes, are device-only and require an unlocked
Keychain; each record is capped at 256 KiB and the channel at 64 live records.
Queue messages carry only the operation/app/backup ID or private-input nonce.
Receipts contain generic completion text. No keys enter public state, HTTP or
ordinary diagnostics. No clone entitlements, hook policy or network admission
flags were changed.

## Bounded encrypted transport

Vercel documents a 4.5 MB function request/response limit:
https://vercel.com/docs/errors/function_payload_too_large
The previous single JSON body could exceed that limit. The new transport sends
1 MiB ciphertext parts (maximum complete ciphertext 200 MiB), never plaintext or
public Blob URLs. Initial metadata binds every part's expected size and SHA-256.
The server validates each part and atomically publishes the backup only after
all acknowledgements. Out-of-order/repeated identical parts are safe. Download
verifies part hashes and the entire ciphertext hash; existing AES-GCM validation
then verifies the encrypted archive before parsing or mutation.

Uploads expire after one hour. At most four unfinished uploads per origin device
are retained. The next upload removes that phone's expired staging after an
additional two-minute grace; expected object keys are known even after a lost
acknowledgement. Completed backups are excluded from that cleanup. An interrupted
client currently starts a new upload on retry; publication acknowledgement loss
is reported as uncertain, so refresh before retrying. Old single-blob backups
remain readable; older clients receive an explicit update error for new chunked
backups. The server retains ordinary backup storage privately and APT separately.

## Evidence and limits

- Real route tests: same-license access, other-owner/license denial, legacy
  provenance, live revocation/expiry/binding validation and scoped deletion.
- Real chunk routes with 6 MiB + 101 bytes: invisible incomplete upload, rejected
  bad/foreign parts, out-of-order/repeated acknowledgements, exact reassembly,
  expiry cleanup and deletion preserving unrelated data.
- Compiled native bridge/transport: 93 assertions with inert HTTP, license and
  Keychain service boundaries; explicit app routing, no HTTP/receipt key,
  corrupted/missing parts and unconfirmed publication all fail.
- Real private Keychain implementation with mocked Security calls: binding,
  device-only protection, expiry, lock/oversize rejection and targeted cleanup.
- Real daemon admission prefix: all three profile aliases, including containerId,
  check persistent owner; malformed profile ownership still blocks foreign work.
- Real export/restore transaction fixture: 192 assertions including decrypted
  wrong-app rejection before mutation. App backup profile flow: 73 assertions.
- Shipped UIKit on a 375-point simulator: 28 assertions, 50 containers, cloud
  receipt consumption/search/picker/confirmation/key expiry. Synthetic service
  data only. Built web UI: nine browser checks, 50 backups, app/search filters,
  confirmation and server-denied deletion, 375-point layout without overflow.

The checks above are host/simulator results. The subsequent 0.1.25 release also
passed a limited physical-device check: upgrade from 0.1.22 preserved both local
profile IDs and the active license. A temporary ldid-signed observer used the
shipped request queue to ask the installed daemon for the Reddit backup list.
The production request succeeded, and the request-bound private Keychain response
was readable and consumed through the shipped SecureConfig implementation. The
list was empty; no user backup was created or deleted. The observer was removed.
Its initial execution from Documents was killed; the identical signed bytes ran
from the existing bootstrap temporary executable location,
without changing trust policy, installed entitlements or sandbox settings.

Device-to-device transfer, actual app login, large-archive memory/throughput,
Keychain accessibility on other physical phones, MDM readoption, jailbreak
injection and network captures remain device acceptance items. On the checked
phone firewall readiness was false and the network gate remained CLOSED.
App Keychain and hardware-bound credentials are NOT included in backups. Neither
video nor these tests establishes universal session portability or 100% isolation.
Existing gap/unverified ledger rows remain open. See
`release-evidence/0.1.25-cloud-workspace.json` and `cloud-workspace-release-0.1.25.md`.
