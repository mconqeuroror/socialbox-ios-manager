#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-keychain-entitlements.XXXXXX")
trap 'rm -f "$BUILD/test" "$BUILD/app-keychain-entitlements.inc"; rmdir "$BUILD"' EXIT HUP INT TERM
python3 - "$ROOT" "$BUILD" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / "tweak/Container/RBXContainerManager.xm").read_text()
start, end = "static BOOL RBXCloneEntitlementsMatchProfile", "static BOOL RBXAcceptanceOwnDefaults"
assert source.count(start) == source.count(end) == 1
(build / "app-keychain-entitlements.inc").write_text(source[source.index(start):source.index(end)])
PY
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation -framework Security \
    -I"$BUILD" -I"$ROOT/shared" "$ROOT/tools/test_app_keychain_entitlements.m" -o "$BUILD/test"
"$BUILD/test"
