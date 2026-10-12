#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-mutation-host.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function -Wno-deprecated-declarations \
  -DLBX_CONTAINER_MUTATION_TESTING=1 -DLBX_CONTAINER_STORE_TESTING=1 -DLBX_LICENSE_OWNER_TESTING=1 \
  -DLBX_LICENSE_VAULT_TESTING=1 -DLBX_LICENSE_TRANSPORT_TESTING=1 -DLBX_LICENSE_EXCHANGE_TESTING=1 \
  -Idaemon -Ishared -framework Foundation -framework Security \
  lucid/tests/container_mutation_coordinator.m lucid/Containers/LBXContainerMutationCoordinator.m \
  lucid/Containers/LBXContainerPendingMutation.m lucid/Containers/LBXContainerConfiguration.m \
  lucid/Containers/LBXContainerIPC.m lucid/Containers/LBXContainerOwner.m \
  lucid/Containers/LBXContainerConfigurationStore.m lucid/Authorization/LBXLicenseOwner.m \
  lucid/Authorization/LBXLicenseIPC.m lucid/Authorization/LBXLicenseVault.m \
  lucid/Authorization/LBXLicenseTransport.m lucid/Authorization/LBXLicenseExchange.m \
  lucid/HelperSafety/LBXCallerFile.m daemon/RBXLicenseToken.m -o "$temporary/test-mutation-coordinator"
"$temporary/test-mutation-coordinator"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
for arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$arch-apple-ios15.0" -isysroot "$sdk" \
    -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function -Wno-deprecated-declarations \
    -Idaemon -Ishared -c lucid/Containers/LBXContainerMutationCoordinator.m -o "$temporary/coordinator-$arch.o"
  if strings "$temporary/coordinator-$arch.o" | rg -q 'testUseLicenseSender:containerSender:|testStopJournalAfterBoundary:'; then
    printf 'FAIL: production %s coordinator object contains a fixture selector\n' "$arch" >&2
    exit 1
  fi
  printf 'PASS: production %s coordinator compilation and fixture selector absence\n' "$arch"
done
