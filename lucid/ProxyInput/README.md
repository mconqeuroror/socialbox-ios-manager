# Recovered-base proxy input integration

`LBXProxyInputHook.m` is linked into the app-only overlay. It intercepts the
reviewed `ProxyViewController.importFromInput:` entrypoint, prepares recognized
addresses locally and dispatches to the original typed add methods. It does not
replace proxy storage, transport, rotation, subscriptions or connection tests.

Supported local inputs include HTTP/HTTPS/SOCKS/SOCKS5 URLs,
`HTTP host:port:user:password`, `SOCKS5 host:port`, and
`user:password@host:port`. IPv6 authorities require brackets. A schemeless
address keeps the original SOCKS5 interpretation; specify HTTP explicitly for
an HTTP provider. Raw provider credentials are literal, including trailing
spaces. URL credentials are percent-decoded once. Invalid credentials are not
silently stripped or replaced.

HTTPS sets the original HTTP method's `tls` argument. A malformed recognized
proxy URL is rejected locally instead of falling into the old subscription
downloader. Subscription URLs remain on the original handler. Shadowsocks
input is delegated to the original `openProxyImportURL:` method; this module
does not claim to validate that protocol. Unknown single inputs also retain
original handling. Mixed subscription/unknown inputs and endpoint lists are
rejected before the first add.

A maximum 256 KB, 500-line input is checked before dispatch. Duplicate endpoints
are removed without merging different protocols or credentials. Every method
needed by a batch is checked before its first add: exact class, directly declared
selector, full Objective-C ABI and implementation in the app executable.
Dispatch stays on the main thread and captures the reviewed implementations.
**Prevalidation is not an atomic backend transaction.** Original add methods
return void; their original reporting and persistence failures still apply.

Error text includes only a line number and instructions, never the address or
credentials. Visible input errors wait for presentation/dismissal transitions
on the main queue, with weak ownership and a bounded two-second retry schedule.
Off-screen imports cannot queue an alert for a future tab. If transitions outlast
the retry budget, a fixed diagnostic message is logged. No input contents are
logged. `safeStatus` reports preparation, not connectivity or isolation.

## Recovered binding

For the pinned 3.1.0/build 1 app, the retained method/instruction inventory maps:

- `importFromInput:`: `0x100214158`, `v24@0:8@16`.
- `addSOCKS5ProxyWithHost:port:user:password:title:rotationUrl:`:
  `0x100216250`, `v64@0:8@16q24@32@40@48@56`.
- `addHTTPProxyWithHost:port:user:password:title:tls:`:
  `0x100216e3c`, `v60@0:8@16q24@32@40@48B56`.
- `openProxyImportURL:`: `0x1002175bc`, `v24@0:8@16`.

Runtime binding uses selectors and verified images, not absolute addresses.
The hook requires the pinned bundle/executable/version/build metadata. An
unsupported method or host leaves original handling installed. The package
builder separately checks the original executable hashes. The simulator seam
is compiled only into the synthetic test executable.

## Verification boundary

`bash lucid/tests/test_proxy_input.sh`: 139 native assertions, including malformed
URLs/ports/percent escapes, raw versus encoded credentials, trailing whitespace,
IPv6, 40 entries, protocol preservation, bounds and all-method prevalidation.

`lucid/Presentation/Tests/run_simulator.py`: 196 combined presentation/proxy
assertions. This runs the actual hook/parser/dispatcher against synthetic UIKit
controllers, including foreign implementation rejection and a reproduced
failing-first alert-dismissal case. The original programs are not executed by
these tests. Actual persistence, authenticated proxy connections, TLS behavior,
subscription fetching and original jailbreak injection still require a phone.

This module reuses SocialBox's `shared/RBXHTTPProxy.m` parser. It does not install
network containment, assert no leaks, migrate licensing or close ADOPT-003/004.
Its leak-register row is ADOPT-005.
