#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-keychain-policy.XXXXXX")
trap 'rm -f "$BUILD/test"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation -framework Security \
    -I"$ROOT/shared" "$ROOT/tools/test_app_keychain_policy.m" -o "$BUILD/test"
"$BUILD/test"
