#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-license-exchange.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function \
  -DLBX_LICENSE_EXCHANGE_TESTING=1 -Idaemon -Ishared -framework Foundation -framework Security \
  lucid/tests/license_exchange.m lucid/Authorization/LBXLicenseExchange.m daemon/RBXLicenseToken.m \
  -o "$temporary/test-license-exchange"
"$temporary/test-license-exchange"
