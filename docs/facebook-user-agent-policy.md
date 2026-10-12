# Facebook producer policy — FBUA-001

The hook covers only `FBUserAgent` in Facebook 578.1.0 (1063022819), as observed in the hash-bound [producer evidence](facebook-user-agent-producer-evidence.json). It does not mark Facebook runnable or its broader defaults/wire policy audited. No Facebook clone has passed on-device producer or transport acceptance.

## Policy and ownership

The producer returns an autoreleased Objective-C string and accepts a flavor word. The wrapper calls it once, preserves every flavor bit, and rewrites only the observed Mozilla OS/build and Facebook device/OS/scale/locale fields using the already validated container profile. Real producer app version, build, revision and unrelated fields remain byte-identical; the minimal variant does not acquire invented app metadata.

Installation requires an enabled registered Facebook descriptor, the manager's exact validated profile, matching container/bundle and complete Keychain metadata, audited source and running bundle versions, and a symbol in this clone's exact FBSharedFramework image. A failed hook attempt cannot be layered with a retry. Captured values are copied and publication is serialized. Unrecognized or ambiguous producer output returns nil with one bounded diagnostic; no complete User-Agent, credentials or opaque identifier value is logged.

## Host verification and limits

`tools/test_facebook_user_agent.py` passes 69 assertions and executes the real policy with observed structures and synthetic metadata. It checks both producer variants, field consistency, preserved app metadata, idempotence, invalid types, duplicate fields, header injection and unsupported profiles. The failing-first policy fixture returned the original UA and failed the Mozilla-prefix consistency assertion.

`tools/test_facebook_user_agent_hooks.py` passes 66 assertions across 19 fresh-process scenarios and compiles the actual installer/wrapper with inert bundle/resolver/substrate services. The production registry admits no Facebook hook. A temporary test-only enabled registry exercises successful installation, immutable binding, flavor forwarding, nil/malformed output, bounded logging and rejection of foreign ownership, versions and images. Missing or invalid non-null trampolines never call the producer and failed attempts are not retried. An additional failing-first fixture exposed the non-null/failed-installation case; the wrapper now requires confirmed installation before invoking any trampoline. The failing-first absent implementation failed the active admission assertion. These are host service simulations, not physical interception or traffic evidence.

The existing Reddit installer branch is unchanged. Facebook `defaults-wire` stays false and the extra producer self-report grants no readiness. Still required: actual paired-clone first-use timing, SDK/defaults persistence and restoration, custom Tigon/MQTT/QUIC behavior, and verified managed VPN routing. A nil fallback may interrupt an unsupported caller; that behavior must be tested on the device before enabling Facebook.
