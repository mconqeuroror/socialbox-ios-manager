#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/redditbox-license-token.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-function \
  -Idaemon -Ishared -framework Foundation -framework Security \
  tests/test_license_token.m daemon/RBXLicenseToken.m -o "$temporary/test-license-token"
"$temporary/test-license-token"
