#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "HTTP proxy/PAC fixtures require macOS Foundation and CFNetwork." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-http-proxy.XXXXXX")
trap 'rm -f "$BUILD/test-http-proxy"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -framework Foundation -framework CFNetwork \
    "$ROOT/shared/RBXHTTPProxy.m" "$ROOT/tools/test_http_proxy.m" -o "$BUILD/test-http-proxy"
"$BUILD/test-http-proxy"
