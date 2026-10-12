#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Fingerprint registry fixtures require macOS Foundation and Xcode command-line tools." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-fingerprint-test.XXXXXX")
trap 'rm -f "$BUILD/test-fingerprint-registry"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -framework Foundation \
    "$ROOT/tools/test_fingerprint_registry.m" -o "$BUILD/test-fingerprint-registry"
"$BUILD/test-fingerprint-registry"
