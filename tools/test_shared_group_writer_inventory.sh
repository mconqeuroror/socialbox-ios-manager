#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
writer_build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-group-writer-test.XXXXXX")
trap 'rm -rf "$writer_build"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -framework Foundation -framework Security \
 tools/test_shared_group_writer_inventory.m lucid/Switching/LBXNativeStorageInventory.m \
 lucid/Switching/LBXNativeIsolationJournal.m lucid/Switching/LBXInstalledApplicationBinding.m \
 lucid/Switching/LBXDarwinDrainBackend.m lucid/Switching/LBXProcessDrain.m \
 lucid/Switching/LBXManagedApplications.m shared/RBXProcessIdentity.m -o "$writer_build/test"
"$writer_build/test"
xcrun clang -c -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -Dmain=SharedGroupWriterProbeUnusedMain lucid/Switching/SharedGroupWriterProbe.m \
  -o "$writer_build/probe.o"
python3 - "$writer_build/probe.o" <<'PY'
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes()
assert b'observeOfficialFacebook:' in data, 'Facebook observe selector missing from family writer probe'
assert b'observeOfficialInstagram:' in data, 'Instagram observe selector missing from family writer probe'
assert b'FAMILY_GROUP_PATH_MISMATCH' in data, 'family group mismatch refusal missing'
print('PASS: family shared-group writer probe captures Instagram and Facebook inventories')
PY
