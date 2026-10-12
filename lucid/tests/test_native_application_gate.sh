#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-native-gate-build.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
test_evidence="${1:-$temporary/evidence}"
mkdir -p "$test_evidence"
chmod 700 "$test_evidence"
test_sources=(lucid/Switching/LBXNativeApplicationGate.h lucid/Switching/LBXNativeApplicationGate.m lucid/Switching/LBXInstalledApplicationBinding.h lucid/Switching/LBXInstalledApplicationBinding.m lucid/Switching/LBXNativeIsolationJournal.h lucid/Switching/LBXNativeIsolationJournal.m lucid/Switching/LBXDarwinDrainBackend.h lucid/Switching/LBXDarwinDrainBackend.m lucid/Switching/LBXProcessDrain.h lucid/Switching/LBXProcessDrain.m lucid/Switching/LBXManagedApplications.h lucid/Switching/LBXManagedApplications.m lucid/Switching/LBXManagedApplications.def shared/RBXStorageGate.h shared/RBXProcessIdentity.h shared/RBXProcessIdentity.m shared/RBXProc.h lucid/tests/native_application_gate.m lucid/tests/test_native_application_gate.sh)
shasum -a 256 "${test_sources[@]}" > "$test_evidence/source-before.sha256"
test_flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations)
test_implementation=(lucid/Switching/LBXNativeApplicationGate.m lucid/Switching/LBXInstalledApplicationBinding.m lucid/Switching/LBXNativeIsolationJournal.m lucid/Switching/LBXDarwinDrainBackend.m lucid/Switching/LBXProcessDrain.m lucid/Switching/LBXManagedApplications.m shared/RBXProcessIdentity.m lucid/tests/native_application_gate.m)
xcrun clang "${test_flags[@]}" -DLBX_INSTALLED_APPLICATION_BINDING_TESTING=1 -DLBX_NATIVE_APPLICATION_GATE_TESTING=1 -DLBX_NATIVE_ISOLATION_JOURNAL_TESTING=1 \
  -framework Foundation "${test_implementation[@]}" -o "$temporary/test-gate" \
  > "$test_evidence/host-compile.log" 2>&1
"$temporary/test-gate" 2>&1 | tee "$test_evidence/host.log"
xcrun clang "${test_flags[@]}" -DLBX_INSTALLED_APPLICATION_BINDING_TESTING=1 -DLBX_NATIVE_APPLICATION_GATE_TESTING=1 -DLBX_NATIVE_ISOLATION_JOURNAL_TESTING=1 -DLBX_PRIVATE_GATE_ABORT_RECOVERY=1 \
  -framework Foundation "${test_implementation[@]}" -o "$temporary/test-private-abort" \
  > "$test_evidence/private-abort-host-compile.log" 2>&1
"$temporary/test-private-abort" 2>&1 | tee "$test_evidence/private-abort-host.log"
xcrun clang "${test_flags[@]}" -framework Foundation "${test_implementation[@]}" \
  -o "$temporary/production-host-gate" > "$test_evidence/production-host-compile.log" 2>&1
"$temporary/production-host-gate" 2>&1 | tee "$test_evidence/production-host.log"
for test_arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$test_arch-apple-ios15.0" "${test_flags[@]}" \
    -c lucid/Switching/LBXNativeApplicationGate.m -o "$test_evidence/gate-$test_arch.o" \
    > "$test_evidence/production-$test_arch-compile.log" 2>&1
done
python3 - "$test_evidence" <<'PY' | tee "$test_evidence/production-boundary.log"
import pathlib, sys
directory = pathlib.Path(sys.argv[1])
for arch in ('arm64', 'arm64e'):
    binary = (directory / f'gate-{arch}.o').read_bytes()
    assert b'captureOfficialFacebookBeforeDeadline:' in binary
    for marker in (b'testUseBackend:', b'testBeforeModeChange:', b'TestRegistration', b'TestBeforeMode', b'LBX_NATIVE_APPLICATION_GATE_TESTING', b'restoreOriginalExecutionForUnstartedProbe:'):
        if marker in binary:
            raise SystemExit(f'FAIL: fixture marker found in production {arch}')
    print(f'PASS: production {arch} compilation and fixture provider absence')
PY
shasum -a 256 "${test_sources[@]}" > "$test_evidence/source-after.sha256"
cmp "$test_evidence/source-before.sha256" "$test_evidence/source-after.sha256"
printf '%s\n' 'PASS: all 19 source inputs unchanged throughout focused validation' | tee "$test_evidence/source-freeze.log"
python3 - "$test_evidence" <<'PY'
import hashlib, json, pathlib, sys
directory = pathlib.Path(sys.argv[1])
evidence = {'kind': 'host-filesystem-and-production-compilation-only', 'deviceExecution': 'NOT_RUN',
            'actualProcessTermination': 'NOT_RUN', 'productionIntegration': 'NOT_RUN',
            'files': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in directory.iterdir() if path.is_file() and path.name != 'evidence.json'}}
(directory / 'evidence.json').write_text(json.dumps(evidence, indent=2, sort_keys=True) + '\n')
PY
