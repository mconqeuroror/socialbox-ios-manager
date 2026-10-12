#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Request deadline fixtures require macOS Foundation and Xcode command-line tools." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-request-deadline.XXXXXX")
trap 'rm -f "$BUILD/test-request-deadlines"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -DRBX_OPERATION_TESTING=1 \
    -I"$ROOT/daemon" -I"$ROOT/shared" -framework Foundation \
    "$ROOT/tools/test_request_deadlines.m" "$ROOT/daemon/RBXOperationContext.m" \
    -o "$BUILD/test-request-deadlines"
"$BUILD/test-request-deadlines"
