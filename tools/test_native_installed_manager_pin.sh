#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-installed-manager-pin-test.XXXXXX")
trap 'rm -rf "$build"' EXIT
flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations)
xcrun clang "${flags[@]}" -framework Foundation -framework Security \
  tools/test_native_installed_manager_pin.m -o "$build/test"
"$build/test"
for arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$arch-apple-ios15.0" "${flags[@]}" \
    -c lucid/Switching/LBXNativeInstalledManagerPin.m -o "$build/pin-$arch.o"
done
python3 - "$build" <<'PY'
from pathlib import Path
import sys
for binary in Path(sys.argv[1]).glob('pin-*.o'):
    data = binary.read_bytes()
    assert b'testObservePath:' not in data, 'fixture API in production pin'
    assert b'performSwitchToContainer:' in data, 'required switch selector missing'
    assert b'method_setImplementation' not in data, 'production pin must not swizzle'
    assert b'installedSwitchConnected' in data
    assert b'doritos' not in data.lower()
    assert b'SocialBox.app' in data
print('PASS: strict arm64/arm64e installed-manager pin compilation; no hook, no fixture API')
PY
