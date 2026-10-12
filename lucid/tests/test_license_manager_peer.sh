#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-manager-peer.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation -lbsm \
  lucid/tests/license_manager_peer.m -o "$temporary/test-manager-peer"
"$temporary/test-manager-peer"
for missing in missing-library missing-ruid missing-euid missing-pid; do
  "$temporary/test-manager-peer" "$missing"
done
