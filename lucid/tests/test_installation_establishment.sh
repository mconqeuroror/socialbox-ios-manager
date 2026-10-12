#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
installation_temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-installation-proof.XXXXXX")"
trap 'rm -rf "$installation_temporary"' EXIT
installation_evidence="${1:-$installation_temporary/evidence}"
mkdir -p "$installation_evidence"
chmod 700 "$installation_evidence"
installation_sources=(lucid/tests/installation_establishment.m lucid/Authorization/LBXLicenseInstallationEstablishment.m
  lucid/Authorization/LBXLicenseVault.m lucid/Containers/LBXContainerConfigurationStore.m lucid/Authorization/LBXLicenseOwner.m
  lucid/Authorization/LBXLicenseIPC.m lucid/Authorization/LBXLicenseTransport.m lucid/Authorization/LBXLicenseExchange.m
  lucid/Containers/LBXContainerConfiguration.m daemon/RBXLicenseToken.m)
shasum -a 256 "${installation_sources[@]}" lucid/Authorization/*.h lucid/Containers/*.h shared/RBXStorageGate.h > "$installation_evidence/source-before.sha256"
installation_flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -Idaemon -Ishared -framework Foundation -framework Security)
installation_definitions=(-DLBX_LICENSE_INSTALLATION_TESTING=1 -DLBX_LICENSE_VAULT_TESTING=1 -DLBX_CONTAINER_STORE_TESTING=1
  -DLBX_LICENSE_OWNER_TESTING=1 -DLBX_LICENSE_TRANSPORT_TESTING=1 -DLBX_LICENSE_EXCHANGE_TESTING=1)
xcrun clang "${installation_flags[@]}" "${installation_definitions[@]}" "${installation_sources[@]}" -o "$installation_temporary/test" > "$installation_evidence/host-compile.log" 2>&1
"$installation_temporary/test" 2>&1 | tee "$installation_evidence/host.log"
xcrun clang "${installation_flags[@]}" "${installation_sources[@]}" -o "$installation_temporary/production" > "$installation_evidence/production-compile.log" 2>&1
"$installation_temporary/production" 2>&1 | tee "$installation_evidence/production.log"
shasum -a 256 "${installation_sources[@]}" lucid/Authorization/*.h lucid/Containers/*.h shared/RBXStorageGate.h > "$installation_evidence/source-after.sha256"
cmp "$installation_evidence/source-before.sha256" "$installation_evidence/source-after.sha256"
