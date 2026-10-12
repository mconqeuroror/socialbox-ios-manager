#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-keychain-hooks.XXXXXX")
trap 'rm -f "$BUILD/test" "$BUILD/app-keychain-wrappers.inc"; rmdir "$BUILD"' EXIT HUP INT TERM
python3 - "$ROOT" "$BUILD" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / "tweak/Container/RBXKeychainHooks.xm").read_text()
start = "static OSStatus (*sync_orig_SecItemAdd)"
assert source.count(start) == 1
(build / "app-keychain-wrappers.inc").write_text(source[source.index(start):])
PY
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation -framework Security \
    -I"$BUILD" -I"$ROOT/shared" "$ROOT/tools/test_app_keychain_hooks.m" -o "$BUILD/test"
"$BUILD/test"
for mode in reddit-default reddit-local facebook-default facebook-local facebook-invalid facebook-unvalidated; do
    "$BUILD/test" "$mode"
done
