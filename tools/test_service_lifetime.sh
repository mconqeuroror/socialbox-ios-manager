#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Service lifetime tests require macOS Foundation and Xcode command-line tools." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-service-test.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-incomplete-implementation \
    -DRBX_OPERATION_TESTING=1 -DRBX_LICENSE_TESTING=1 "-DRBX_LICENSE_CLOUD_PLIST=@\"$BUILD/cloud.plist\"" \
    "-DRBX_LICENSE_STATE_PLIST=@\"$BUILD/license-state.plist\"" \
    -I"$ROOT/daemon" -I"$ROOT/shared" -framework Foundation -framework Security \
    "$ROOT/tools/test_service_lifetime.m" "$ROOT/daemon/RBXOperationContext.m" "$ROOT/daemon/RBXLicenseToken.m" \
    -o "$BUILD/test-service-lifetime"
"$BUILD/test-service-lifetime"
