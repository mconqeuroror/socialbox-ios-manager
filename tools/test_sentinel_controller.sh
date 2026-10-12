#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/rbx-sentinel-controller.XXXXXX")
trap 'rm -f "$BUILD/test"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-nullability-completeness \
    -DRBX_OPERATION_TESTING=1 \
    -I"$ROOT/daemon" -I"$ROOT/shared" -framework Foundation -framework Security \
    "$ROOT/tools/test_sentinel_controller.m" -o "$BUILD/test"
"$BUILD/test"
