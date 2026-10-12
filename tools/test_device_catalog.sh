#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Catalog and profile loader tests require macOS Foundation and Xcode command-line tools." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-catalog-test.XXXXXX")
trap 'rm -f "$BUILD/test-device-catalog"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -I"$ROOT/daemon" -I"$ROOT/shared" \
    -framework Foundation "$ROOT/tools/test_device_catalog.m" \
    "$ROOT/daemon/RBXProfileIO.m" "$ROOT/daemon/RBXProfileGenerator.m" \
    "$ROOT/daemon/RBXConsistencyValidator.m" "$ROOT/shared/RBXMGOverrides.m" \
    -o "$BUILD/test-device-catalog"
"$BUILD/test-device-catalog" "$ROOT/profiles/catalog.json"
