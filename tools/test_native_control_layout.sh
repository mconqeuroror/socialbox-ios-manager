#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-control-layout-test.XXXXXX")
trap 'rm -rf "$build"' EXIT
flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations)
xcrun clang "${flags[@]}" -DLBX_NATIVE_CONTROL_LAYOUT_TESTING=1 -framework Foundation \
  lucid/Switching/LBXNativeControlLayout.m tools/test_native_control_layout.m -o "$build/test"
"$build/test"
for arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$arch-apple-ios15.0" "${flags[@]}" \
    -c lucid/Switching/LBXNativeControlLayout.m -o "$build/layout-$arch.o"
  xcrun --sdk iphoneos clang -target "$arch-apple-ios15.0" "${flags[@]}" \
    -c lucid/Switching/NativeControlLayoutProbe.m -o "$build/probe-$arch.o"
done
python3 - "$build" <<'PY'
from pathlib import Path
import sys
for binary in Path(sys.argv[1]).glob('*.o'):
    data = binary.read_bytes()
    assert b'testObserveContainers:' not in data, 'fixture API in production control layout'
    assert b'accountFileContentsRead' in data
    if binary.name.startswith('layout-'):
        assert b'com.facebook.Facebook' in data
        assert b'com.burbn.instagram' in data
        assert b'com.twitter.twitter' not in data
    if binary.name.startswith('probe-'):
        assert b'observeOfficialFamily:' in data
        assert b'native-family-control-layout.json' in data
        assert b'isolationVerified' in data
        assert b'com.twitter.twitter' not in data
    assert b'doritos' not in data.lower()
print('PASS: strict arm64/arm64e family control-layout compilation; no fixture API')
PY
