#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-native-switch-test.XXXXXX")
trap 'rm -rf "$build"' EXIT
flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations)
xcrun clang "${flags[@]}" \
  -DLBX_NATIVE_SWITCH_COORDINATOR_TESTING=1 \
  -DLBX_NATIVE_BROKER_TESTING=1 \
  -DLBX_NATIVE_CONTROL_STORE_TESTING=1 \
  -DLBX_NATIVE_ISOLATION_JOURNAL_TESTING=1 \
  -framework Foundation \
  lucid/Switching/LBXNativeIsolationJournal.m \
  lucid/Switching/LBXNativeBrokerAuthority.m \
  lucid/Switching/LBXNativeControlStore.m \
  lucid/Switching/LBXNativeSwitchCoordinator.m \
  lucid/Switching/LBXProcessDrain.m \
  lucid/Switching/LBXManagedApplications.m \
  tools/test_native_switch_coordinator.m \
  -o "$build/test"
"$build/test"
for arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$arch-apple-ios15.0" "${flags[@]}" \
    -c lucid/Switching/LBXNativeSwitchCoordinator.m -o "$build/switch-$arch.o"
done
python3 - "$build" <<'PY'
from pathlib import Path
import sys
for binary in Path(sys.argv[1]).glob('switch-*.o'):
    data = binary.read_bytes()
    assert b'testOpenJournal:' not in data
    assert b'testSetDrain:' not in data
    assert b'testSetFence:' not in data
    assert b'attachControlLayout:' in data
    assert b'attachFamilyApplicationGate:' in data
    assert b'testSetDrain:' not in data
print('PASS: strict arm64/arm64e switch-coordinator compilation; fixture APIs absent')
PY
