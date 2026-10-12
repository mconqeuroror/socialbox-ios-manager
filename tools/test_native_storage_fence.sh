#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-fence-build.XXXXXX")
trap 'rm -rf "$build"' EXIT
fence_evidence="${1:-$build/evidence}"
mkdir -p "$fence_evidence"
chmod 700 "$fence_evidence"
inputs=(lucid/Switching/LBXNativeStorageFence.h lucid/Switching/LBXNativeStorageFence.m lucid/Switching/LBXNativeStorageInventory.h lucid/Switching/LBXNativeStorageLayout.h lucid/Switching/LBXNativeStorageLayout.m lucid/Switching/LBXNativeApplicationGate.h lucid/Switching/LBXNativeIsolationJournal.h lucid/Switching/LBXNativeIsolationJournal.m shared/RBXStorageGate.h tools/test_native_storage_fence.m tools/test_native_storage_fence.sh)
shasum -a 256 "${inputs[@]}" > "$fence_evidence/source-before.sha256"
flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations)
xcrun clang "${flags[@]}" \
  -DLBX_NATIVE_STORAGE_FENCE_TESTING=1 -DLBX_NATIVE_ISOLATION_JOURNAL_TESTING=1 -framework Foundation \
  tools/test_native_storage_fence.m lucid/Switching/LBXNativeStorageFence.m \
  lucid/Switching/LBXNativeStorageLayout.m lucid/Switching/LBXNativeIsolationJournal.m -o "$build/test" \
  > "$fence_evidence/host-compile.log" 2>&1
"$build/test" 2>&1 | tee "$fence_evidence/host.log"
for fence_arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$fence_arch-apple-ios15.0" "${flags[@]}" \
    -c lucid/Switching/LBXNativeStorageFence.m -o "$fence_evidence/fence-$fence_arch.o" \
    > "$fence_evidence/production-$fence_arch-compile.log" 2>&1
done
python3 - "$fence_evidence" <<'PY' | tee "$fence_evidence/production-boundary.log"
import pathlib, sys
folder = pathlib.Path(sys.argv[1])
for arch in ('arm64', 'arm64e'):
    binary = (folder / f'fence-{arch}.o').read_bytes()
    for marker in (b'testUseRoot:', b'testSetReopenDescriptor:', b'testSetCheckpoint:', b'ReopenDescriptor', b'TestRoot'):
        if marker in binary:
            raise SystemExit(f'FAIL: fixture marker in production {arch}')
    print(f'PASS: strict production {arch} compilation and fixture API absence')
PY
shasum -a 256 "${inputs[@]}" > "$fence_evidence/source-after.sha256"
cmp "$fence_evidence/source-before.sha256" "$fence_evidence/source-after.sha256"
printf '%s\n' 'PASS: all 11 source inputs unchanged during validation' | tee "$fence_evidence/source-freeze.log"
python3 - "$fence_evidence" <<'PY'
import hashlib, json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
result = {'kind': 'host-filesystem-flags-journal-fork-recovery-and-production-compilation',
          'processAndInventoryAuthority': 'FIXTURE_STUBS', 'deviceExecution': 'NOT_RUN',
          'uidBoundaryEnforcement': 'NOT_RUN', 'runtimeIsolationAccepted': False,
          'files': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.iterdir()
                    if p.is_file() and p.name != 'evidence.json'}}
(folder / 'evidence.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
PY
