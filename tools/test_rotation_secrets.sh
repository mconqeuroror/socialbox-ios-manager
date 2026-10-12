#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Rotation-secret tests require macOS Foundation/Security; no real Keychain is read." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-secrets.XXXXXX")
trap 'rm -f "$BUILD/test"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -I"$ROOT/shared" -I"$ROOT/daemon" \
    -framework Foundation -framework Security "$ROOT/tools/test_rotation_secrets.m" -o "$BUILD/test"
"$BUILD/test"
