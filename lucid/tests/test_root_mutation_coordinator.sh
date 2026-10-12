#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source lucid/tests/production_selector_guard.sh
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-root-coordinator.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function -Wno-deprecated-declarations \
  -DLBX_CONTAINER_ROOT_COORDINATOR_TESTING=1 -DLBX_CONTAINER_ROOT_PENDING_TESTING=1 \
  -DLBX_CONTAINER_STORE_TESTING=1 -DLBX_LICENSE_OWNER_TESTING=1 -DLBX_LICENSE_VAULT_TESTING=1 \
  -DLBX_LICENSE_TRANSPORT_TESTING=1 -DLBX_LICENSE_EXCHANGE_TESTING=1 \
  -Idaemon -Ishared -framework Foundation -framework Security \
  lucid/tests/root_mutation_coordinator.m lucid/Containers/LBXContainerRootMutationCoordinator.m \
  lucid/Containers/LBXContainerRootMutationOwner.m lucid/Containers/LBXContainerRootPendingStore.m \
  lucid/Containers/LBXContainerConfigurationStore.m lucid/Containers/LBXContainerConfiguration.m \
  lucid/Containers/LBXContainerMutationIPC.m lucid/Containers/LBXContainerIPC.m \
  lucid/Authorization/LBXLicenseOwner.m lucid/Authorization/LBXLicenseVault.m \
  lucid/Authorization/LBXLicenseIPC.m lucid/Authorization/LBXLicenseTransport.m \
  lucid/Authorization/LBXLicenseExchange.m daemon/RBXLicenseToken.m -o "$temporary/test-root-coordinator"
"$temporary/test-root-coordinator"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
for arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$arch-apple-ios15.0" -isysroot "$sdk" \
    -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function -Wno-deprecated-declarations \
    -Idaemon -Ishared -c lucid/Containers/LBXContainerRootMutationCoordinator.m -o "$temporary/coordinator-$arch.o"
  check_production_selectors "$temporary/coordinator-$arch.o" "$arch" "$temporary/selectors-$arch.txt"
done
