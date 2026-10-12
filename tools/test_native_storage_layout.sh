#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-layout.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -DLBX_NATIVE_STORAGE_LAYOUT_TESTING=1 -framework Foundation \
  "$root/tools/test_native_storage_layout.m" "$root/lucid/Switching/LBXNativeStorageLayout.m" -o "$build/test"
"$build/test"
