#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
capture_test_build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-capture-build.XXXXXX")
trap 'rm -rf "$capture_test_build"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -framework Foundation -framework Security \
 tools/test_native_storage_fence_probe.m lucid/Switching/LBXNativeStorageInventory.m \
 lucid/Switching/LBXNativeStorageLayout.m lucid/Switching/LBXNativeFamilyStorageLayout.m lucid/Switching/LBXNativeStorageFence.m \
 lucid/Switching/LBXNativeApplicationGate.m lucid/Switching/LBXNativeIsolationJournal.m \
 lucid/Switching/LBXInstalledApplicationBinding.m lucid/Switching/LBXDarwinDrainBackend.m \
 lucid/Switching/LBXProcessDrain.m lucid/Switching/LBXManagedApplications.m shared/RBXProcessIdentity.m \
 -o "$capture_test_build/test"
"$capture_test_build/test"
