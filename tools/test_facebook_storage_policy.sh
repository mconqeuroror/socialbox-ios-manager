#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/fb-storage-policy.XXXXXX")
trap 'rm -f "$build/test"; rmdir "$build"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I"$ROOT/shared" -framework Foundation "$ROOT/tools/test_facebook_storage_policy.m" -o "$build/test"
"$build/test"
