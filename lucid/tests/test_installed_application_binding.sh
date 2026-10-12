#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-installed-binding-build.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
test_evidence="${1:-$temporary/evidence}"
mkdir -p "$test_evidence"
chmod 700 "$test_evidence"
test_sources=(lucid/Switching/LBXInstalledApplicationBinding.h lucid/Switching/LBXInstalledApplicationBinding.m lucid/tests/installed_application_binding.m lucid/tests/test_installed_application_binding.sh)
shasum -a 256 "${test_sources[@]}" > "$test_evidence/source-before.sha256"
test_flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations)
xcrun clang "${test_flags[@]}" -DLBX_INSTALLED_APPLICATION_BINDING_TESTING=1 \
  -framework Foundation lucid/Switching/LBXInstalledApplicationBinding.m \
  lucid/tests/installed_application_binding.m -o "$temporary/test-binding" \
  > "$test_evidence/host-compile.log" 2>&1
"$temporary/test-binding" 2>&1 | tee "$test_evidence/host.log"
xcrun clang "${test_flags[@]}" -framework Foundation \
  lucid/Switching/LBXInstalledApplicationBinding.m lucid/tests/installed_application_binding.m \
  lucid/Switching/LBXDarwinDrainBackend.m lucid/Switching/LBXProcessDrain.m \
  lucid/Switching/LBXManagedApplications.m shared/RBXProcessIdentity.m \
  -o "$temporary/production-host-binding" > "$test_evidence/production-host-compile.log" 2>&1
"$temporary/production-host-binding" 2>&1 | tee "$test_evidence/production-host.log"
for test_arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$test_arch-apple-ios15.0" "${test_flags[@]}" \
    -c lucid/Switching/LBXInstalledApplicationBinding.m -o "$test_evidence/binding-$test_arch.o" \
    > "$test_evidence/production-$test_arch-compile.log" 2>&1
done
python3 - "$test_evidence" <<'PY' | tee "$test_evidence/production-boundary.log"
import pathlib, sys
directory = pathlib.Path(sys.argv[1])
for arch in ('arm64', 'arm64e'):
    binary = (directory / f'binding-{arch}.o').read_bytes()
    assert b'observeOfficialFacebook:' in binary
    for marker in (b'testUseRegistration:', b'testAfterOpeningFile:', b'testAfterFinalRegistration:', b'LBX_INSTALLED_APPLICATION_BINDING_TESTING'):
        if marker in binary:
            raise SystemExit(f'FAIL: fixture marker found in production {arch}')
    print(f'PASS: production {arch} compilation and fixture provider absence')
PY
shasum -a 256 "${test_sources[@]}" > "$test_evidence/source-after.sha256"
cmp "$test_evidence/source-before.sha256" "$test_evidence/source-after.sha256"
printf '%s\n' 'PASS: four source files unchanged throughout focused validation' | tee "$test_evidence/source-freeze.log"
python3 - "$test_evidence" <<'PY'
import hashlib, json, pathlib, sys
directory = pathlib.Path(sys.argv[1])
evidence = {'kind': 'host-and-production-compilation-only', 'deviceExecution': 'NOT_RUN',
            'files': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in directory.iterdir() if path.is_file() and path.name != 'evidence.json'}}
(directory / 'evidence.json').write_text(json.dumps(evidence, indent=2, sort_keys=True) + '\n')
PY
