#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Deletion journal tests require macOS Foundation and Xcode command-line tools; all paths are temporary fixtures." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-deletion-test.XXXXXX")
trap 'rm -f "$BUILD/test-deletion-journal"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-function \
    -I"$ROOT/shared" -I"$ROOT/daemon" -framework Foundation \
    "$ROOT/tools/test_deletion_journal.m" -o "$BUILD/test-deletion-journal"
"$BUILD/test-deletion-journal" "$ROOT/tools/fixtures/profile-identifiers.json"
