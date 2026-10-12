# Experimental PF policy, compiler and readback

This directory implements preparation units for **NET-040**, absent from every shipping target. The policy/reducer performs no I/O. The separate compiler/reader permits seven read-only PF queries through an injected transport; its private device CLI opens `/dev/pf` read-only. Nothing here installs rules, enables PF, clears states, changes routes/radios/preferences or controls a process. `applicationAdmissionAllowed` is always false, including after a matching readback or successful modeled transaction. No result is a production readiness receipt.

The actual phone capability and its unchanged signed diagnostic receipts are documented in [the no-MDM feasibility report](../../docs/no-mdm-network-feasibility-2026-09-20.md). This module does not replace those observations or change their NOT_RUN verdicts.

## Implemented policy contract

`RBXPFPolicyPlan` accepts an exact field set: boot UUID, generation UUID, bounded container ID, `scope=device-wide-proxy-only`, `transport=http`, 1–16 unique external IPv4 literals, a numeric port and `recoveryMode=out-of-band`. It rejects unknown fields, credentials, proxy URLs, hostnames, IPv6 proxy addresses, SOCKS/TLS-to-proxy, private/link-local/multicast addresses, broad root-UID exceptions, DNS/cloud/rotation exceptions and USB recovery requests. There is no resolver and no direct fallback.

The immutable typed rule AST has two forms:

- Closed: one final, quick block covering both IP families and both directions.
- Candidate: exact outbound TCP `/32` destination and port rules, SYN admission with state tracking, followed by that same default block. IPv6 and UDP/DNS/QUIC have no pass rule. Return TCP traffic relies on PF state handling, which has not been physically tested by this module.

Rules contain bounded PF labels derived from the complete binding. Changing the generation changes the rule labels, not only a separate receipt hash. The SHA-256 plan digest covers canonical sorted JSON, the binding and ordered rules. That digest is **not** Apple's 16-byte `pf_chksum`; the compiler/reader below validates complete rule semantics, order, labels and ownership before reporting the corresponding plan digest. Matching a label alone is insufficient.

The planner does not establish that an address is reachable or is a valid proxy. It accepts no proxy password, token or authentication header. HTTP authentication remains the existing transport's responsibility.

## Kernel compiler and read-only verifier

`RBXPFKernelPolicy` recompiles a validated plan into the pinned 64-bit Apple
rule representation. Named offsets are checked against separately acquired,
hash-pinned `xnu-8796.141.3` headers. Unconstructed objects and mutated plans
are rejected; compiled rule arrays, data and digests have no mutable setters.

`RBXPFKernelReader` requires two agreeing observations of PF enable state,
all six root ruleset families/tickets, complete ordered filter rules and creator
UID/PID, empty address pools, no child anchors and PF interface flags. Every
rule byte must match except the kernel-computed skip array and runtime traffic/
reference counters. Routing, masks, ports, tags, timeouts, limits and reserved
fields remain significant. A hidden pool or `PFI_IFLAG_SKIP` interface fails
even when labels match. No raw rule records or kernel pointers are exported.

Empty mode requires disabled PF and no rules/states/source nodes. Closed mode's
CLI invocation also requires no retained state. Proxy mode may inspect active
states but cannot attest how those flows were admitted. Counts, sizing and
elapsed time are bounded; a blocked kernel ioctl still needs external process
supervision. Counter resets are forbidden. Two observations are **not atomic**
and cannot exclude an ABA change between reads or prove physical filtering.

The primary references are Apple's
[pfvar.h](https://github.com/apple-oss-distributions/xnu/blob/xnu-8796.141.3/bsd/net/pfvar.h)
and [pf_ioctl.c](https://github.com/apple-oss-distributions/xnu/blob/xnu-8796.141.3/bsd/net/pf_ioctl.c).
Upstream source is not copied into this module.

### Private diagnostic

`scripts/build-pf-readback.py --output <new-private-directory> --ldid <procursus-ldid>`
builds separate arm64/arm64e tools, uses explicit empty entitlements and ad-hoc
signing, verifies signatures/architectures and records source/binary hashes.
It does not install or publish anything.

Use `socialbox-pf-readback-arm64 --empty` for the empty baseline. An eventual
installed policy can be inspected with `--closed` or `--proxy`, followed by
`--plan <json-file> --creator-pid <actual-writer-pid>`; JSON uses the exact planner
schema. Unsupported kernels, malformed input, FIFOs and symlinks are rejected.
The runtime is restricted to the previously measured iPhone10,6 kernel
`22.6.0 / xnu-8796.142.1.703.8 / RELEASE_ARM64_T8015`. Host invocations cannot
open PF. Every report explicitly denies enforcement verification and admission.

## Transaction contract

The reducer must run on one serialized control queue. Its requests are instructions for a future trusted adapter, with fresh challenges, sequences and boot/generation/container bindings. Acknowledgements in the tests are simulated observations; they are not authenticated kernel evidence.

The ordinary path is:

1. Verify that an out-of-band recovery path exists; inspect an empty, disabled PF baseline.
2. Fence and drain all earlier mutation work. Register a fresh mutation-fence token.
3. Atomically compare-and-swap the expected baseline to the closed policy, then verify enabled PF and exact policy order/digest.
4. Purge retained states and verify zero remaining states. Stop and verify the exact registered app processes; reread closed policy/order/states before reporting modeled closure.
5. Arm an independent revoker with a finite deadline at most 2.5 seconds away and an explicit deny-plus-state-purge contract.
6. Compare-and-swap the closed policy to the candidate policy, then verify its actual order/digest before reporting only `proxy-policy-model-only`.

Five-second operation deadlines, the revoker deadline, nonfinite/backwards time, errors and interruptions invalidate positive state. A pending candidate write invalidates modeled CLOSED before a callback arrives. If its completion is ambiguous, recovery may compare-and-swap either of the **two exact owned policy digests**; it may not overwrite an unknown policy. Failed recovery leads to emergency app-stop instructions and `operator-recovery-required`, not a fabricated CLOSED status. Recovery never automatically retries candidate opening.

An interruption starts with all evidence invalid. After checking recovery and reading a recognized owned policy, it fences writers again, establishes deny, revokes states and verifies processes. The informational `journalSummary` has `restorableAsVerifiedState=false`; no deserializer can restore an OPEN/CLOSED proof from it. Boot identity must come from a fresh trusted source. Reboot ownership/admission integration remains an external requirement.

### Why the mutation fence is required

An old candidate-write request can pass a plain digest CAS after a newer recovery restores the same closed digest: a delayed write could otherwise reopen after CLOSED was acknowledged. Rejecting its late callback does not undo the kernel write.

The adapter must drain/cancel previous writers, enforce the fresh fence token and record a monotonically increasing committed sequence. `RBXPFMutationMatchesFence` is the tested predicate for that contract. Its check, actual kernel commit and sequence update **must be inside the same serialized lock/fence owner**. Checking it before queueing a helper is unsafe. Detached helper processes, crash recovery and competing policy writers must participate in the same barrier. A boolean acknowledgement without that implementation is not sufficient evidence.

Apple's `DIOCXCOMMIT` checks the **inactive transaction ticket**, not the old
active checksum; `DIOCCHANGERULE` can modify active rules independently.
A pre-read plus a userspace lock therefore does not exclude arbitrary PF
writers. The model's CAS acknowledgement remains an unimplemented contract:
a writer needs a reviewed ownership/coexistence design. Ordinary PF commit
must not be presented as satisfying it. No blind loader is added.

## Boundaries that remain open

- **Per-app attribution:** ordinary apps share mobile UID. These rules allow every process to reach the same approved proxy endpoint; they do not identify the selected container. Exact app/lease control, original-app routing and unsolicited/background-launch acceptance remain separate work.
- **Brokers/shared proxy:** proxy credentials and a destination allowlist do not prove which clone or broker initiated a request. There are no general root, loopback or licensing exceptions in this plan. Broker and shared-proxy misuse need an independently enforced admission design and in-app tests.
- **Revoker death:** a static PF allow rule does not expire on its own. The model requires a revoker acknowledgement but cannot prove the revoker survives or closes traffic when it dies. A physical revoker/daemon-death design and packet evidence are still mandatory; the mocked acknowledgement does not close this gap.
- **USB recovery:** preserving IPv6 SSH also involves exact interface/tuple ownership, Neighbor Discovery, retained-state revocation and reconnect behavior. The first planner rejects that mode rather than granting a broad local-network or ICMP exception. Do not load this candidate remotely with USB SSH as the only recovery path.
- **Network lifecycle:** automatic configuration, DHCP, IPv6 proxy/Neighbor Discovery, VPN coexistence and interface handoff are not supported by this first policy contract. A steady-state IPv4 rule AST is not proof of a usable device-wide network backend.
- **Kernel mutations:** compiler/readback exist; loader, transaction ownership, state revocation, process adapter, guardian, boot hook and production receipt consumer do not. Unrecognized policies with rules/anchors are rejected rather than replaced.

The next end-to-end prerequisite is an isolated adapter that implements the fenced CAS, preserves foreign policy, reads back the full resulting policy and revokes retained states, with a reviewed recovery path and independent expiry enforcement. It must first be tested using disposable synthetic clients and physical traffic capture. A working phone uplink, deliberate operator recovery setup, and later actual app/broker tests are needed before any production admission can change. No MDM requirement or license/UI readiness check was bypassed.

## Validation

Run `bash tools/test_pf_policy_plan.sh`. The actual Objective-C implementation is compiled under ASan/UBSan with Foundation; the current suite has **596 native assertions**. It covers strict inputs, immutable/deterministic binding, rule labels, stale/wrong/replayed acknowledgement rejection, retained states/processes, exact readback, missing recovery/guardian evidence, timeouts, expiry, invalid time, interruption, ambiguous writes, mutation-fence replay and failure at every modeled operation.

Independent review found mutable digest exposure and the delayed-write CAS hazard. Both received behavioral regressions and fixes. Earlier failing cases also established that pending candidate writes must invalidate CLOSED and that generation changes must alter kernel-representable labels. An arm64-iOS syntax build verifies compatibility with the target compiler. These results are **host/model PASS; kernel loading and physical network enforcement NOT_RUN**.

`bash tools/test_pf_kernel_policy.sh` runs **1,365 native compiler/readback
assertions** under ASan/UBSan, six real CLI test methods and arm64/arm64e syntax
checks. It mutates all 1,040 rule bytes and injects 31 inspection faults,
including skip flags, hidden pools, foreign rules, changed tickets/creators,
races, malformed inventories, retained states and invalid/expired clocks.
The unconstructed-policy regression rejects the object before any query.

`python3 tools/test_pf_kernel_abi.py --headers <pinned-header-directory>` runs
the existing **112** diagnostic ABI checks on host/arm64 plus **86** new checks
on host/arm64/arm64e. CLI deployment, enabled-rule readback, state drain and
physical packet acceptance remain **NOT_RUN**.
