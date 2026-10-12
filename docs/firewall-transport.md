# C09: managed app-proxy transport

The extension now implements `NEAppProxyProvider` on iOS 15+. Its existing
`com.redditbox.firewall.PacketTunnel` bundle identifier is retained for the
daemon protocol; the extension point is `com.apple.networkextension.app-proxy`.
There is no packet discard loop, excluded route, or `includeAllNetworks` setting.

The MDM per-app assignment diverts managed app flows to this provider. In OPEN,
only the active clone's TCP streams to the configured proxy host/address and
port are accepted. The provider opens a native connection to a daemon-resolved
numeric proxy address and relays bytes in both directions with backpressure.
H15 limits the upstream to `http://host:port`: the app/CFNetwork path owns HTTP
forwarding, CONNECT and supported proxy authentication; the relay passes that
already-proxied stream through without another proxy wrapper. SOCKS5 and
TLS-to-proxy (`https://` proxy URLs) were removed/rejected. An HTTPS destination
still uses CONNECT through the HTTP proxy; it does not require an HTTPS proxy URL.
Unknown apps, direct Internet destinations and non-DNS UDP are denied.
The clone signer explicitly sets its CodeDirectory identifier (`ldid -I`) to
the clone bundle identifier, which the provider checks in flow metadata.
Existing clones without this signing marker are rebuilt during migration.
DNS A/AAAA queries for the proxy hostname are answered locally from the lease;
other names receive NXDOMAIN and no DNS request leaves the provider.

Every admission and asynchronous relay callback checks the current lease.
Revocation closes both ends of every accepted flow before CLOSED status is
published. The 100 ms monitor also closes idle streams after expiry, daemon
restart or lease change. Provider status identifies the `app-proxy` transport;
the daemon and hooks reject acknowledgements from the previous packet provider.

## Upgrade requirements

1. Build/sign both targets with `scripts/build-mac.sh`: unsigned Xcode archive,
   then Procursus ldid and the checked-in `app-proxy-provider`/App Group
   entitlements. This path needs no Apple team or provisioning profile. Whether
   the chosen jailbreak/iOS authorizes those signatures and entitlements is
   unverified; the old packet-provider package is insufficient.
2. Regenerate and deploy the MDM payload (`VPN.ProviderType=app-proxy`) with
   Connect-only on-demand rules and every clone/source managed-app assignment.
   Replace the previous packet VPN configuration; retain no Disconnect rules.
3. Open firewall setup to start that managed configuration. The host loads
   `NEAppProxyProviderManager` configurations; it cannot create an app proxy
   locally. Unmanaged or unassigned applications are outside this guarantee.

HTTP proxy authentication was addressed in H15, with end-to-end device testing
still required. Separate OAuth service-process authorization remains open after
phase 3: the provider publishes `outOfProcessAuthCovered=false` and the web-auth
hook refuses `ASWebAuthenticationSession.start`. SafariDomains in the export do
not authorize a browser process in the provider's active-clone admission check.
Shared Reddit callback schemes also remain an ownership issue across clones.

H08 is still an implementation gap: managed-app status plus configured bundle
lists/per-app scope do not prove the effective clone-to-VPNUUID association.
Use the [device acceptance runbook](on-device-smoke-checklist.md) for the exact
Mac build, MDM attribute deployment, browser-login triage and A/B capture steps.
Keep these unverified gates open until evidence or an implementation fix resolves
each one; a provider status flag is not routing proof.

## Validation

`bash tools/test_firewall_policy.sh` compiles the actual policy and DNS code in
Swift 5 mode and exercises allow/deny, expiry, epoch, empty allowlist, wrong
bundle/port, IPv4/IPv6 DNS and malformed queries. `scripts/build-mac.sh` runs it
before the Xcode archive. These native tests and the archive require macOS.

On an enrolled iPhone with verified clone assignments, capture the physical interface while testing:

- OPEN: transfer in both directions through the proxy; IPv4/IPv6 and hostname
  endpoints work. The only provider TCP destination is the authorized proxy.
- CLOSED/ARMED: no TCP egress, including direct IP, bound-interface connections,
  QUIC/UDP, a different clone and the original Reddit app. Only local proxy DNS
  answers are possible in ARMED.
- Hold a long-lived transfer and an idle socket open, then revoke the lease:
  both terminate, and neither can resume on a later generation.
- Suspend/kill the daemon: within 2.5 s plus the monitor interval all streams
  close. Resume/restart it: an old OPEN lease cannot renew or reopen.
- Kill/stop the provider during transfer: verify iOS holds/fails assigned-app
  connections until the Connect-only per-app VPN restarts; verify there is no
  direct fallback. Do not certify release without this device test.
- Remove the App Group write permission and change generations during an
  asynchronous settings update: no stale completion may acknowledge OPEN.

Apple references:
[app-proxy lifecycle and DNS](https://developer.apple.com/documentation/networkextension/neappproxyprovider),
[MDM-only configurations](https://developer.apple.com/documentation/networkextension/neappproxyprovidermanager),
[flow lifecycle](https://developer.apple.com/documentation/networkextension/neappproxyflow),
[per-app routing](https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic).

## Without an MDM service

The operator confirmed no MDM service on 2026-09-18. The installed 0.1.35 build
has no accepted no-MDM transport. Offline preparation remains available, but
removing the managed-installation checks would not provide network enforcement.
Do not present buying/enrolling in MDM alone as sufficient: adoption of the
exact ldid clones and effective routing still need device evidence.

Apple permits manual installation of the [AppLayerVPN payload](https://developer.apple.com/documentation/devicemanagement/applayervpn)
on iOS and requires supervision for this payload only on watchOS. However, its
[provider deployment rules](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
restrict iOS app-proxy use to managed devices and require the targeted apps to
be installed with MDM. These are separate requirements. Settings, Diagnostics
and the firewall host no longer incorrectly call iOS supervision mandatory;
no enforcement or entitlements changed.

Jailbreak-local policy is an investigation, not an implemented replacement.
Apple's [iOS 16-era XNU source](https://github.com/apple-oss-distributions/xnu/blob/xnu-8796.121.2/bsd/net/necp.c)
provides NECP policy sessions, but `necp_session_open` checks platform signing
and root/privilege, and `necp_session_op_close` deletes that session's policies.
A daemon-owned deny rule alone therefore does not prove fail-closed behavior
when its process dies. A candidate must demonstrate persisted closure, exact
per-clone attribution (including delegated traffic), IPv4/IPv6, DNS/UDP denial,
proxy-only TCP and failure/restart behavior before admission can change.
The presence of `/dev/pf`, private selectors or a successful local configuration
write is insufficient. A device-wide packet tunnel would also change the scope
to other apps; it is not silently substituted for the current per-app design.

During inspection the previously tested iPhone 8 was unavailable over USB/SSH;
the Mac reported an iPhone X instead. Target confirmation is pending. No policy
was installed, no VPN started and no phone erased during this investigation.

Validation of this wording-only correction: static checks and leak-surface
contract passed; operator wording, launch-safety, MDM export, firewall policy/DNS,
app gate readiness (71 assertions), and app gate control (34 assertions for each
fixture) passed. The launcher compiled for arm64/arm64e with the root Makefile's
warning flags, and the firewall host passed iOS Swift typechecking. No no-MDM
runtime test or replacement transport is claimed. This correction was not
installed or published as a new package.
