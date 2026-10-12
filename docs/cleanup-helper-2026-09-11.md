# Cleanup helper: iOS 16.7.7 observations

Rows: LIFE-026, LIFE-027. This is a bounded cleanup correction, not a full isolation verdict.

On the connected rootless iPhone, deleting our own failed test container returned
`Helper exited unsuccessfully`. Its deletion journal remained prepared/retryable.
No existing user container or recovery journal was discarded.

Two independent observations reproduced the failure:

- Identical ldid-signed cleaner bytes exited 137 under `/var/mobile`, but executed
  inside the rootless bootstrap. Rootless jobs now use durable bootstrap
  `/var/lib/redditbox/keychain-cleanup`, resolved through the existing install-path
  helper. Rootful retains its existing path. Both old and new roots are checked
  for unproven helper-exit fences; migration cannot bypass old recovery evidence.
- After successful `setgroups(0, NULL)`, `setgid(501)` and `setuid(501)`, Darwin
  reported one group, 501. Requiring an empty group list incorrectly rejected
  valid mobile credentials. The cleaner now permits only an empty list or exactly
  the primary mobile group. Extra groups, inspection errors, wrong UID/GID and
  restoration of root remain failures before Security access.

The native fixture failed before the credential correction and passed afterward.
It tests both group representations, extra groups, failed inspection, failed
privilege drop, excess entitlements, denied/locked canaries, retained key records
and preservation of a second synthetic group. The deletion journal fault suite
also passed. Tests do not access the Mac keychain.

A separately signed exact-group probe on the phone returned `status=cleared`,
`proof=true`, uid/gid 501 and all four classes after the correction. It targeted
only our failed test container, which had never completed installation. That
probe is not substituted for a daemon journal receipt and does not establish
cross-container isolation. Full daemon retry, installed-clone lifecycle, locked
phone, interrupted cleanup and rootful device behavior need distinct acceptance.
