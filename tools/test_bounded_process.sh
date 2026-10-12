#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Bounded process tests require Darwin process groups and macOS Foundation." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-child-build.XXXXXX")
trap 'rm -f "$BUILD/fixture" "$BUILD/test-bounded-process"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -Wall -Wextra "$ROOT/tools/bounded_process_fixture.c" -o "$BUILD/fixture"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -DRBX_OPERATION_TESTING=1 \
    -I"$ROOT/daemon" -I"$ROOT/shared" -framework Foundation "$ROOT/tools/test_bounded_process.m" \
    "$ROOT/daemon/RBXOperationContext.m" -o "$BUILD/test-bounded-process"
"$BUILD/test-bounded-process" "$BUILD/fixture"
