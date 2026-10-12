#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/fb-group-store.XXXXXX")
trap 'rm -f "$build/test"; rmdir "$build"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I"$ROOT/shared" -framework Foundation "$ROOT/tools/test_facebook_private_group_store.m" -o "$build/test"
"$build/test"
