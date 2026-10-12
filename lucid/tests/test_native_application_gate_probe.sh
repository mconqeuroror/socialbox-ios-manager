#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-gate-probe-tests.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -framework Foundation \
    lucid/tests/native_application_gate_probe.m lucid/Switching/LBXNativeApplicationGate.m \
    lucid/Switching/LBXNativeIsolationJournal.m lucid/Switching/LBXInstalledApplicationBinding.m \
    lucid/Switching/LBXDarwinDrainBackend.m lucid/Switching/LBXProcessDrain.m \
    lucid/Switching/LBXManagedApplications.m shared/RBXProcessIdentity.m -o "$temporary/probe-tests"
"$temporary/probe-tests"
