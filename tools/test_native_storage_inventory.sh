#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
inventory_test_build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-native-storage-test.XXXXXX")
trap 'rm -rf "$inventory_test_build"' EXIT
inventory_flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations)
xcrun clang "${inventory_flags[@]}" -DLBX_NATIVE_STORAGE_INVENTORY_TESTING=1 -framework Foundation \
  lucid/Switching/LBXNativeStorageInventory.m tools/test_native_storage_inventory.m -o "$inventory_test_build/test"
"$inventory_test_build/test"
for inventory_arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$inventory_arch-apple-ios15.0" "${inventory_flags[@]}" \
    -c lucid/Switching/LBXNativeStorageInventory.m -o "$inventory_test_build/inventory-$inventory_arch.o"
  xcrun --sdk iphoneos clang -target "$inventory_arch-apple-ios15.0" "${inventory_flags[@]}" \
    -c lucid/Switching/NativeStorageInventoryProbe.m -o "$inventory_test_build/probe-$inventory_arch.o"
done
python3 - "$inventory_test_build" <<'PY'
from pathlib import Path
import sys
for binary in Path(sys.argv[1]).glob('*.o'):
    data = binary.read_bytes()
    assert not any(marker in data for marker in (b'testObserveRegistration:', b'testMatchesRegistration:', b'testClassifySnapshot:')), 'fixture API in production object'
    assert b'observeOfficialFacebook:' in data, 'Facebook observe selector missing'
    if binary.name.startswith('probe-'):
        assert b'layoutWithInstagram:facebook:error:' in data, 'family layout selector missing from inventory probe'
print('PASS: strict arm64/arm64e inventory and private probe compilation; no fixture API')
PY
