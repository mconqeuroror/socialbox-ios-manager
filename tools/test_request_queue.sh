#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Native request queue tests require macOS Foundation and Xcode command-line tools." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-queue-build.XXXXXX")
trap 'rm -f "$BUILD/test-request-queue"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -framework Foundation \
    "$ROOT/shared/RBXRequestQueue.m" "$ROOT/tools/test_request_queue.m" \
    -o "$BUILD/test-request-queue"
"$BUILD/test-request-queue"
