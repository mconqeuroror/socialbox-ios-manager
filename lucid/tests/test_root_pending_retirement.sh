#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-root-retirement-tests.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function -Wno-deprecated-declarations \
  -DLBX_CONTAINER_ROOT_PENDING_TESTING=1 -DLBX_CONTAINER_STORE_TESTING=1 \
  -DLBX_LICENSE_OWNER_TESTING=1 -DLBX_LICENSE_VAULT_TESTING=1 \
  -DLBX_LICENSE_TRANSPORT_TESTING=1 -DLBX_LICENSE_EXCHANGE_TESTING=1 \
  -Idaemon -Ishared -framework Foundation -framework Security \
  lucid/tests/root_pending_retirement.m lucid/Containers/LBXContainerRootPendingStore.m \
  lucid/Containers/LBXContainerRootMutationOwner.m lucid/Containers/LBXContainerMutationIPC.m \
  lucid/Containers/LBXContainerIPC.m lucid/Containers/LBXContainerConfiguration.m \
  lucid/Containers/LBXContainerConfigurationStore.m lucid/Authorization/LBXLicenseOwner.m \
  lucid/Authorization/LBXLicenseVault.m lucid/Authorization/LBXLicenseIPC.m \
  lucid/Authorization/LBXLicenseTransport.m lucid/Authorization/LBXLicenseExchange.m \
  daemon/RBXLicenseToken.m -o "$temporary/root-pending-retirement"
"$temporary/root-pending-retirement"
