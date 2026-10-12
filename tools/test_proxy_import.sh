#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-proxy-import.XXXXXX")
trap 'rm -f "$BUILD/test"; rmdir "$BUILD"' EXIT
xcrun clang -fobjc-arc -fblocks -I"$ROOT/shared" -framework Foundation -framework CFNetwork -Wno-incomplete-implementation "$ROOT/shared/RBXProxyLibrary.m" "$ROOT/shared/RBXHTTPProxy.m" "$ROOT/tools/test_proxy_import.m" -o "$BUILD/test"
"$BUILD/test"
