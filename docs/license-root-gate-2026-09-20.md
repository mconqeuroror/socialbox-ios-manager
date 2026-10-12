# License-only entry screen

Leak-Surface: CLOUD-001, UI-007, UI-010

The launcher now decides its whole window root from the existing daemon license
publication before showing a window. Without a fresh valid grant, only the
SocialBox lock screen, license-key field, Activate button and concise status are
constructed. There is no app selector, tab bar, Settings, Cloud or container view
behind the entry screen. The established production origin and Keychain storage
are reused; this change creates no license and changes no signing key.

A revoke, expiry, malformed or stale publication replaces the entire workspace,
including any presented sheet. Darwin notifications and a local one-second
timer refresh the gate. An opaque cover hides background snapshots; foreground
activation checks the publication before removing it. The Facebook deep link
checks both at delivery and at its queued callback. A valid grant still requires
the independent launcher passcode when one is configured. The daemon remains
the authority for all licensed operations; this UI is an additional access gate.

The detailed Account & license page remains available after unlocking. It reads
the current publication on appearance, foreground and timer updates; it is not
used as the locked root. Enter submits the same guarded Activate action as the
button. No hidden page is needed to activate with an existing key.

## Regression evidence

- Actual root UIKit fixture compiled with baseline `0b4c46f`: five failures in
  five checks, reproducing the existing tabs, excess controls and premature
  workspace construction while unlicensed.
- Final root UIKit fixture: **49 checks PASS**, including cold launch, key-only
  layout, grant, revocation from Facebook with a presented sheet, stale/expired/
  malformed publications, background cover, timer expiry, queued deep-link
  revocation, retired tabs and the separate passcode.
- Full workspace UIKit regression: **240 checks PASS** after teaching the
  fixture to retrieve the new workspace following a grant. Existing Cloud,
  creation, selection, proxy, settings and recovery checks remain active.
- License-screen native fixture: **33 checks PASS**; launcher multi-app,
  launcher architecture and static checks pass.

These UI tests use the actual launcher implementation with inert IPC, synthetic
publication and synthetic Keychain values. They do not contact the licensing
server, test a real entitlement, or establish physical-device isolation. The
recording and screenshots are retained privately in the task workspace at
`private-device/license-gate-2026-09-20/verified/` and
`private-device/license-gate-2026-09-20/license-gate-verified.mp4`.
