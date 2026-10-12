#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Keychain cleaner control-flow tests require macOS Foundation and Xcode command-line tools; all Security calls are synthetic." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-keychain-test.XXXXXX")
trap 'rm -f "$BUILD/test-keychain-cleaner"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -framework Foundation -framework Security \
    "$ROOT/tools/test_keychain_cleaner.m" -o "$BUILD/test-keychain-cleaner"
"$BUILD/test-keychain-cleaner"
