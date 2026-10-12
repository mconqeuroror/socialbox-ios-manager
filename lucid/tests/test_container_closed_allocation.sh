#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-closed-allocation.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function -Wno-deprecated-declarations \
  -DLBX_CONTAINER_CLOSED_ALLOCATION_TESTING=1 -DLBX_CONTAINER_IDENTITY_SPECIFICATION_TESTING=1 \
  -DLBX_CONTAINER_STORE_TESTING=1 -DLBX_LICENSE_OWNER_TESTING=1 -DLBX_LICENSE_VAULT_TESTING=1 \
  -DLBX_LICENSE_TRANSPORT_TESTING=1 -DLBX_LICENSE_EXCHANGE_TESTING=1 -Idaemon -Ishared \
  -framework Foundation -framework Security lucid/tests/container_closed_allocation.m \
  lucid/Containers/LBXContainerClosedAllocation.m lucid/Containers/LBXContainerIdentitySpecification.m \
  lucid/Containers/LBXContainerConfiguration.m lucid/Containers/LBXContainerConfigurationStore.m \
  lucid/Authorization/LBXLicenseOwner.m lucid/Authorization/LBXLicenseIPC.m \
  lucid/Authorization/LBXLicenseVault.m lucid/Authorization/LBXLicenseTransport.m \
  lucid/Authorization/LBXLicenseExchange.m daemon/RBXLicenseToken.m -o "$temporary/test-closed-allocation"
"$temporary/test-closed-allocation"
