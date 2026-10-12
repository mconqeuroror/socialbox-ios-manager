#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-region-test.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -I"$ROOT/daemon" -I"$ROOT/shared" \
    -framework Foundation "$ROOT/tools/test_proxy_region.m" "$ROOT/daemon/RBXProfileIO.m" -o "$BUILD/test"
"$BUILD/test" "$ROOT/profiles/catalog.json"
