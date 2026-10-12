#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-passcode-test.XXXXXX")
trap 'rm -f "$BUILD/test-passcode"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-function -Wno-unused-parameter \
    -Wno-deprecated-declarations -framework Foundation -framework Security \
    "$ROOT/tools/test_passcode_store.m" -o "$BUILD/test-passcode"
"$BUILD/test-passcode"
