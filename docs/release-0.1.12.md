# Proxy-based region defaults

Branch: `feat/lifecycle-and-distribution`, unmerged.
Affected rows: UI-001, UI-002, UI-003, ID-003, LIFE-023, NET-038, LIFE-029.

New containers use a fresh lookup through the selected device proxy when the
country field is empty. An explicit country remains available. Lookup failure
stops before creating a container. The identity editor's **Set from proxy**
fills geographical draft fields without replacing UUIDs or device identifiers;
Check and Save remain explicit. Used identities remain frozen.

The daemon uses the container's assigned proxy when one exists. Otherwise it
uses the selected device proxy as a suggestion for the requested region. It
does not assign that proxy to the container: cloud assignment and all launch
gates remain authoritative. Changing selection or assignment during lookup
invalidates the result. The lookup does not rotate, persist a profile or open
a clone network lease.

Country and available timezone/city are IP geolocation estimates. Locale and
carrier are catalog suggestions; a network owner/ASN is not a detected SIM
carrier. A city absent from the catalog is shown separately from the suggested
catalog city in the same timezone. Unknown countries/zones fail rather than
pretending to be US. Missing optional city/timezone fields are labelled as
catalog suggestions. Supported country catalog remains US, CA, GB, DE, FR, ES,
IT, NL, AU and JP; this is not worldwide coverage or exact GPS detection.

Catalog cities now have explicit timezones. New generation and city selection
use those zones, including western/central US, Canadian and Australian cities.
Saved profiles are not silently migrated. Editing an old city/timezone mismatch
requires selecting a consistent city/zone or using Set from proxy.

Primary references: [IPinfo legacy API response availability](https://support.ipinfo.io/hc/en-us/articles/34121895556242-Legacy-Free-API-vs-IPinfo-Lite)
and [IANA timezone descriptions](https://data.iana.org/time-zones/tzdb/zone1970.tab).
IPinfo can fail or rate-limit the lookup; there is no direct connection fallback.

## Validation

Native parser fixtures cover invalid responses, IPv4/IPv6 syntax, unsupported
country/timezone, provenance and city fallback. Native transport fixtures
execute the shipped method with injected storage/HTTP boundaries, checking
exact assigned/selected proxy, no rotation, no persistence, stale results,
locked identity, HTTP failure and missing operation ownership. The catalog
suite checks generated city/timezone coherence across all 59 model/OS tuples.

Touchscreen rendering/taps, rootful hardware, managed clone launch and full A/B
isolation need separate device acceptance. Missing MDM/per-app VPN remains a
launch prerequisite; this feature does not remove that requirement.

## Connected rootless phone

`release-evidence/0.1.12-proxy-region.json` records a successful live lookup
through the user's selected device proxy, exact preview and Save with all
identifiers/model/OS preserved, and a new auto-region container created and
removed through the normal daemon actions. The test confirmed cloud assignment
was not overwritten and no raw identifiers appeared in public state/receipts.
The observed city was Miami; the catalog suggested New York in the same timezone,
explicitly marked as a suggestion. No exact Miami location was claimed.
The pre-existing test container remains; startup recovery is healthy and no
operation-recovery marker remains. These are backend tests, not touchscreen or
full managed-launch acceptance.

## Published packages

Rootless **0.1.12** and rootful **0.1.10** are published at the existing
[installation page](https://redditspoof.vercel.app/install). Both signed APT
indexes, all retained downloads, local metadata, displayed versions and Sileo
links passed production verification. Both staging license checks passed before
promotion. The existing license public key still matches the cloud signer.
Both publication journals completed under the shared lock; delayed lock/index
visibility was handled with the same journal owners and normal `--resume`.
No lock was stolen or deleted manually.

The phone disconnected after successful feature acceptance, before the final
published package could be copied/reinstalled. Its last verified installed
version is the locally tested rootless 0.1.12 build; its SHA differs from the
final release rebuild. Final published-byte device installation is therefore
**NOT RUN**, not claimed complete. Rootful hardware and managed clone launch
remain **NOT RUN**. Branch remains unmerged.
