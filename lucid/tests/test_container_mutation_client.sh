#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-root-mutation-client.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation \
  lucid/Containers/LBXContainerConfiguration.m lucid/Containers/LBXContainerMutationIPC.m \
  lucid/tests/container_mutation_client.m -o "$temporary/test-root-mutation-client"
"$temporary/test-root-mutation-client"
