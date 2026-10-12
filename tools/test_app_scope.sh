#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rbx-app-scope.XXXXXX")
trap 'rm -f "$temporary/test" "$temporary/test-ipc"; rmdir "$temporary"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -I"$ROOT/launcher" -I"$ROOT/shared" -framework Foundation \
    "$ROOT/tools/test_app_scope.m" -o "$temporary/test"
"$temporary/test"

xcrun clang -fobjc-arc -fblocks -Wno-nullability-completeness -I"$ROOT/launcher" -I"$ROOT/shared" -framework Foundation \
    "$ROOT/tools/test_app_ipc.m" -o "$temporary/test-ipc"
"$temporary/test-ipc"
