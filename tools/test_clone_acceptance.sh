#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Clone acceptance fixtures require macOS Foundation/Security; no real Security calls are made." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-acceptance-build.XXXXXX")
trap 'rm -f "$BUILD/test-clone-acceptance"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -framework Foundation -framework Security \
    "$ROOT/tools/test_clone_acceptance.m" -o "$BUILD/test-clone-acceptance"
"$BUILD/test-clone-acceptance"
