#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Backup snapshot tests require macOS Foundation/SQLite; all paths are temporary fixtures." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-snapshot.XXXXXX")
trap 'rm -f "$BUILD/test"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -I"$ROOT/shared" -I"$ROOT/daemon" \
    -framework Foundation -lsqlite3 "$ROOT/tools/test_backup_snapshot.m" -o "$BUILD/test"
"$BUILD/test"
