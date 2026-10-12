#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-manager-bridge-test.XXXXXX")
trap 'rm -rf "$build"' EXIT
flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations)
xcrun clang "${flags[@]}" \
  -DLBX_NATIVE_SWITCH_COORDINATOR_TESTING=1 \
  -DLBX_NATIVE_BROKER_TESTING=1 \
  -DLBX_NATIVE_CONTROL_STORE_TESTING=1 \
  -DLBX_NATIVE_ISOLATION_JOURNAL_TESTING=1 \
  -DLBX_NATIVE_STORAGE_LAYOUT_TESTING=1 \
  -DLBX_NATIVE_INSTALLED_MANAGER_PIN_TESTING=1 \
  -DLBX_NATIVE_CONTROL_LAYOUT_TESTING=1 \
  -framework Foundation \
  lucid/Switching/LBXNativeIsolationJournal.m \
  lucid/Switching/LBXNativeBrokerAuthority.m \
  lucid/Switching/LBXNativeControlStore.m \
  lucid/Switching/LBXNativeSwitchCoordinator.m \
  lucid/Switching/LBXProcessDrain.m \
  lucid/Switching/LBXManagedApplications.m \
  lucid/Switching/LBXNativeStorageLayout.m \
  lucid/Switching/LBXNativeFamilyStorageLayout.m \
  lucid/Switching/LBXNativeInstalledManagerPin.m \
  lucid/Switching/LBXNativeControlLayout.m \
  lucid/Switching/LBXNativeManagerBridge.m \
  tools/test_native_manager_bridge.m \
  -o "$build/test"
"$build/test"
for arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$arch-apple-ios15.0" "${flags[@]}" \
    -c lucid/Switching/LBXNativeManagerBridge.m -o "$build/bridge-$arch.o"
done
python3 - "$build" <<'PY'
from pathlib import Path
import sys
for binary in Path(sys.argv[1]).glob('bridge-*.o'):
    data = binary.read_bytes()
    assert b'performSwitchToContainer:' not in data
    assert b'switchToGlobalContainer:' not in data
    assert b'manager-pin-required' in data
    assert b'method_setImplementation' not in data
print('PASS: strict arm64/arm64e manager-bridge compilation; original switch selectors absent')
PY
