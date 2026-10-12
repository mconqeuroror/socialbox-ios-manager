#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-native-control-test.XXXXXX")
trap 'rm -rf "$build"' EXIT
flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations)
xcrun clang "${flags[@]}" -DLBX_NATIVE_CONTROL_STORE_TESTING=1 -DLBX_NATIVE_ISOLATION_JOURNAL_TESTING=1 -framework Foundation \
  lucid/Switching/LBXNativeIsolationJournal.m lucid/Switching/LBXNativeControlStore.m tools/test_native_control_store.m \
  -o "$build/test"
"$build/test"
for arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$arch-apple-ios15.0" "${flags[@]}" \
    -c lucid/Switching/LBXNativeControlStore.m -o "$build/control-$arch.o"
done
python3 - "$build" <<'PY'
from pathlib import Path
import sys
for binary in Path(sys.argv[1]).glob('control-*.o'):
    data = binary.read_bytes()
    assert b'testOpenJournal:' not in data
print('PASS: strict arm64/arm64e control-store compilation; fixture APIs absent')
PY
