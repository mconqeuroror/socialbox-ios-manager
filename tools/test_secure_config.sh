#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Native secure configuration tests require macOS Foundation, Security, and Xcode command-line tools." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-config-build.XXXXXX")
trap 'rm -f "$BUILD/test-secure-config"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -framework Foundation -framework Security \
    "$ROOT/shared/RBXSecureConfig.m" "$ROOT/tools/test_secure_config.m" \
    -o "$BUILD/test-secure-config"
"$BUILD/test-secure-config"
