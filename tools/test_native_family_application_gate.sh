#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-family-application-gate-test.XXXXXX")
trap 'rm -rf "$build"' EXIT
flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations)
xcrun clang "${flags[@]}" -framework Foundation \
  lucid/Switching/LBXNativeFamilyApplicationGate.m tools/test_native_family_application_gate.m \
  -o "$build/test"
"$build/test"
for arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$arch-apple-ios15.0" "${flags[@]}" \
    -c lucid/Switching/LBXNativeFamilyApplicationGate.m -o "$build/family-gate-$arch.o"
done
python3 - "$build" <<'PY'
from pathlib import Path
import sys
for binary in Path(sys.argv[1]).glob('family-gate-*.o'):
    data = binary.read_bytes()
    assert b'com.facebook.Facebook' in data
    assert b'com.burbn.instagram' in data
    assert b'com.twitter.twitter' not in data
    assert b'isolationVerified' in data
    assert b'method_setImplementation' not in data
print('PASS: strict arm64/arm64e family application-gate compilation')
PY
