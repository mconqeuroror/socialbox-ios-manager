#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-pending-host.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function -Wno-deprecated-declarations \
  -DLBX_CONTAINER_MUTATION_TESTING=1 -Idaemon -Ishared -framework Foundation \
  lucid/tests/container_pending_mutation.m lucid/Containers/LBXContainerPendingMutation.m \
  lucid/Containers/LBXContainerConfiguration.m lucid/HelperSafety/LBXCallerFile.m \
  -o "$temporary/test-pending-mutation"
"$temporary/test-pending-mutation"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
for arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$arch-apple-ios15.0" -isysroot "$sdk" \
    -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function -Wno-deprecated-declarations \
    -Idaemon -Ishared -c lucid/Containers/LBXContainerPendingMutation.m -o "$temporary/pending-$arch.o"
  if strings "$temporary/pending-$arch.o" | rg -q 'testUseHomeDirectory:|testStopAfterBoundary:'; then
    printf 'FAIL: production %s pending object contains a fixture selector\n' "$arch" >&2
    exit 1
  fi
  printf 'PASS: production %s pending compilation and fixture selector absence\n' "$arch"
done
