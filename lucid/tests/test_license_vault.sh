#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-license-vault.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function \
  -DLBX_LICENSE_VAULT_TESTING=1 -Idaemon -Ishared -framework Foundation -framework Security \
  lucid/tests/license_vault.m lucid/Authorization/LBXLicenseVault.m lucid/Authorization/LBXLicenseIPC.m daemon/RBXLicenseToken.m \
  -o "$temporary/test-license-vault"
"$temporary/test-license-vault"
