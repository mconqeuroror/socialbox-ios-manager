#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-exception.XXXXXX")
trap 'rm -f "$BUILD/test"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang++ -std=c++17 -fobjc-arc -fblocks -framework Foundation "$ROOT/tools/test_exception_port_guard.mm" -o "$BUILD/test"
"$BUILD/test"
