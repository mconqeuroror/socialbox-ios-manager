# Setup checklist and launch safety

Rootless 0.1.14 / rootful 0.1.12 adds a red/green checklist in Settings and a
missing-check count on Containers. Each step has a direct setup action. Green
means the stated observation passed; stale, missing and unverified evidence is
red and explicitly labelled. A two-second display timer expires green states
even if the daemon stops publishing.

The steps are daemon status, data/recovery, signed license validity, imported
source, saved proxy, current proxy connection test, running managed provider,
MDM installation of each clone, retained isolation alerts, and separate VPN/A-B
acceptance. MDM-managed installation is observed through the existing
LaunchServices check. It is **not proof of the effective clone-to-VPNUUID
association**. The routing/A-B acceptance row remains unverified because no
automatic setup flag can establish packet diversion or cross-sandbox denial.

Prepare an offline clone before asking MDM to adopt its exact IPA and assign the
per-app VPN. Re-export after rebuilding the clone. This order avoids requiring
an MDM-managed clone before one exists. Supervision/enrolment and MDM deployment
must come from an actual MDM service; they cannot be granted by a local toggle.
Follow [device acceptance](device-acceptance-final.md) after deployment.

## Proxy input and connection evidence

Both proxy entry screens use one normalizer. It accepts `host:port`,
`host:port:user:password`, `user:password@host:port`, HTTP URLs, bracketed IPv6
provider notation, and a copied `HTTP ` label. Credentials from provider
notation are encoded once and are not interpreted as URL escapes. Repeated
normalization preserves the endpoint and credentials. Unsupported protocols,
missing/invalid ports, invalid hostnames and control characters are rejected.
No credential guessing, protocol downgrade or DIRECT retry is performed.

A proxy test records the configuration revision observed before and after the
test. A changed configuration rejects the result. Green expires after five
minutes, immediately after any local configuration change, or after the daemon
publication becomes stale. Every Open independently validates its proxy again.

For daemon proxy health and geography requests, actual Foundation transaction
metrics must identify the selected proxy's numeric peer address and explicit
port for every network transaction. Hostname resolution reuses the bounded,
single-worker daemon resolver. Missing metrics, cache-only results and missing
peer details cannot pass; an unexpected peer blocks the request and therefore
the dependent Open. The returned exit address must be valid numeric IPv4/IPv6;
the existing identity-country check remains required.

Starting another proxy test invalidates the previous result before network work.
Settings compares receipt completion time with the latest daemon test; an older
cached success cannot hide a newer failure, pending test, timeout or cancellation.

The Foundation `isProxyConnection` flag alone is insufficient: the local PAC
transport fixture observed `NO` while the proxy server received the absolute
HTTP request. Peer address/port evidence handles that case. These metrics
describe the daemon health connection; they do not certify all clone traffic.
The per-app provider and lease checks remain required. See Apple's
[transaction metrics](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics)
and [remote address](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/remoteaddress).

## Isolation findings

A retained sentinel LEAK blocks the next Open, including when the sentinel is
subsequently disabled. The daemon refreshes observer state with a three-second
caller deadline and checks safety before a switch and again before granting
OPEN. Missing/corrupt safety state also rejects admission. The observer does not
terminate an already-open session. Lease, provider and license enforcement
still handle their own revocations. There is no unconditional reset button;
review and repair a finding before returning that profile to service.

## Verification

- `tools/test_proxy_library.sh`: regression first failed against the old parser;
  new parsing, idempotence, credential preservation, CRUD and license retention pass.
- `tools/test_launch_safety.sh`: retained/OFF/historical alerts, malformed state,
  peer mismatch, missing/cached metrics, stale configuration results and scoped
  checklist statuses.
- `tools/test_proxy_route_transport.py`: actual Foundation requests to loopback
  fixtures through the shipped daemon wrapper. A selected proxy peer succeeds;
  a direct request to a different listener fails. This tests real metrics and
  delegate ordering without contacting an external service.
- Existing hook, firewall, lifecycle, configuration and source-import checks
  remain required by both native builds.

Device A/B denial, actual per-app routing during provider failure, and native
screen interaction require the iPhone and deployed MDM configuration. Host
tests cannot establish 100% isolation. Current release evidence belongs in the
versioned release notes, not an inferred all-clear state.

Rows: UI-001, UI-004, NET-034, NET-036, NET-038, LIFE-021, ACCEPT-005.
