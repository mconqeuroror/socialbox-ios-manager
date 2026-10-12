#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-native-broker-test.XXXXXX")
trap 'rm -rf "$build"' EXIT
flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations)
xcrun clang "${flags[@]}" -DLBX_NATIVE_BROKER_TESTING=1 -DLBX_NATIVE_ISOLATION_JOURNAL_TESTING=1 -framework Foundation \
  lucid/Switching/LBXNativeIsolationJournal.m lucid/Switching/LBXNativeBrokerAuthority.m tools/test_native_broker_authority.m \
  -o "$build/test"
"$build/test"
for arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$arch-apple-ios15.0" "${flags[@]}" \
    -c lucid/Switching/LBXNativeBrokerAuthority.m -o "$build/broker-$arch.o"
done
python3 - "$build" <<'PY'
from pathlib import Path
import sys
for binary in Path(sys.argv[1]).glob('broker-*.o'):
    data = binary.read_bytes()
    assert b'testOpenJournal:' not in data
    assert b'testObserveApplication:' not in data
    assert b'testSetKernelObservation:' not in data
    assert b'testSetBootIdentity:' not in data
print('PASS: strict arm64/arm64e broker compilation; fixture APIs absent')
PY
