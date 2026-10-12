#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Keychain sync policy tests require macOS Foundation and Security." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-keychain-sync.XXXXXX")
trap 'rm -f "$BUILD/test-keychain-sync" "$BUILD/keychain-sync-wrappers.inc"; rmdir "$BUILD"' EXIT HUP INT TERM
python3 - "$ROOT" "$BUILD" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / "tweak/Container/RBXKeychainHooks.xm").read_text()
start = "static OSStatus (*sync_orig_SecItemAdd)"
end = "// BEGIN APP KEYCHAIN WRAPPERS"
assert source.count(start) == source.count(end) == 1
# Exercise the actual shipped Security wrappers with synthetic providers.
(build / "keychain-sync-wrappers.inc").write_text(source[source.index(start):source.index(end)])
PY
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -framework Foundation -framework Security \
    -I"$BUILD" \
    "$ROOT/tools/test_keychain_sync.m" -o "$BUILD/test-keychain-sync"
"$BUILD/test-keychain-sync"
