#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Operation context tests require macOS Foundation and Xcode command-line tools." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-context-test.XXXXXX")
trap 'rm -f "$BUILD/test-operation-context"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -DRBX_OPERATION_TESTING=1 \
    -I"$ROOT/daemon" -I"$ROOT/shared" -framework Foundation -framework CFNetwork \
    "$ROOT/tools/test_operation_context.m" "$ROOT/shared/RBXHTTPProxy.m" \
    -o "$BUILD/test-operation-context"
"$BUILD/test-operation-context"
