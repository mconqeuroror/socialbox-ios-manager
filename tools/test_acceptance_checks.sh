#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RBX_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$RBX_TEST_DIR"' EXIT
xcrun clang -fobjc-arc -fblocks -Ishared -framework Foundation shared/RBXAcceptanceChecks.m tools/test_acceptance_checks.m -o "$RBX_TEST_DIR/test"
"$RBX_TEST_DIR/test"
xcrun clang -fobjc-arc -fblocks -Ishared -framework Foundation shared/RBXAcceptanceChecks.m tools/device_acceptance_cli.m -o "$RBX_TEST_DIR/cli"
printf '{}\n' | "$RBX_TEST_DIR/cli" 1000 >/dev/null
