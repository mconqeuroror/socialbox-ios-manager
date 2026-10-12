#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-container-ipc.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -framework Foundation lucid/Containers/LBXContainerConfiguration.m \
  lucid/Containers/LBXContainerIPC.m lucid/tests/container_ipc.m \
  -o "$temporary/test-container-ipc"
"$temporary/test-container-ipc"
