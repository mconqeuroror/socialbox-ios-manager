#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-family-switch-library.XXXXXX")
trap 'rm -rf "$build"' EXIT
flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -Ishared)
files=(
  lucid/Switching/LBXNativeIsolationJournal.m
  lucid/Switching/LBXNativeBrokerAuthority.m
  lucid/Switching/LBXNativeControlStore.m
  lucid/Switching/LBXNativeStorageInventory.m
  lucid/Switching/LBXNativeStorageLayout.m
  lucid/Switching/LBXNativeFamilyStorageLayout.m
  lucid/Switching/LBXInstalledApplicationBinding.m
  lucid/Switching/LBXNativeApplicationGate.m
  lucid/Switching/LBXNativeFamilyApplicationGate.m
  lucid/Switching/LBXNativeStorageFence.m
  lucid/Switching/LBXNativeControlLayout.m
  lucid/Switching/LBXNativeInstalledManagerPin.m
  lucid/Switching/LBXNativeSwitchCoordinator.m
  lucid/Switching/LBXNativeManagerBridge.m
  lucid/Switching/LBXDarwinDrainBackend.m
  lucid/Switching/LBXProcessDrain.m
  lucid/Switching/LBXManagedApplications.m
  shared/RBXProcessIdentity.m
)
xcrun clang "${flags[@]}" -dynamiclib -framework Foundation \
  "${files[@]}" -o "$build/libLBXNativeFamilySwitch.dylib"
python3 - "$build/libLBXNativeFamilySwitch.dylib" <<'PY'
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes()
assert b'attachFamilyApplicationGate:' in data
assert b'attachControlLayout:' in data
assert b'observeOfficialFacebook:' in data
assert b'captureOfficialFacebookBeforeDeadline:' in data
assert b'manager-pin-required' in data
assert b'Filter' not in data
assert b'com.saurik.substrate' not in data
print('PASS: uninjected family-switch dylib links Instagram/Facebook contracts; no Substrate filter')
PY
