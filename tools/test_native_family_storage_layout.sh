#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-family-layout-test.XXXXXX")
trap 'rm -rf "$build"' EXIT
flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations)
xcrun clang "${flags[@]}" -DLBX_NATIVE_STORAGE_LAYOUT_TESTING=1 -framework Foundation \
  lucid/Switching/LBXNativeStorageLayout.m lucid/Switching/LBXNativeFamilyStorageLayout.m \
  tools/test_native_family_storage_layout.m -o "$build/test"
"$build/test"
for arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$arch-apple-ios15.0" "${flags[@]}" \
    -c lucid/Switching/LBXNativeFamilyStorageLayout.m -o "$build/family-$arch.o"
done
python3 - "$build" <<'PY'
from pathlib import Path
import sys
for binary in Path(sys.argv[1]).glob('family-*.o'):
    data = binary.read_bytes()
    assert b'testLayoutForSnapshot:' not in data
print('PASS: strict arm64/arm64e family-layout compilation; fixture APIs absent')
PY
