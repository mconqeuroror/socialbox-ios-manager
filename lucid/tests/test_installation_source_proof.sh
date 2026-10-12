#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
proof_temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-source-proof.XXXXXX")"
trap 'rm -rf "$proof_temporary"' EXIT
proof_evidence="${1:-$proof_temporary/evidence}"
mkdir -p "$proof_evidence"
chmod 700 "$proof_evidence"
proof_units=(lucid/tests/installation_source_proof.m lucid/Authorization/LBXLicenseInstallationEstablishment.m
  lucid/Authorization/LBXLicenseVault.m lucid/Containers/LBXContainerConfigurationStore.m lucid/Authorization/LBXLicenseOwner.m
  lucid/Authorization/LBXLicenseIPC.m lucid/Authorization/LBXLicenseTransport.m lucid/Authorization/LBXLicenseExchange.m
  lucid/Containers/LBXContainerConfiguration.m daemon/RBXLicenseToken.m)
proof_sources=("${proof_units[@]}" lucid/tests/installation_establishment.m lucid/tests/test_installation_source_proof.sh
  lucid/Authorization/LBXLicenseInstallationEstablishment.h lucid/Authorization/LBXLicenseVault.h
  lucid/Authorization/LBXLicenseOwner.h lucid/Authorization/LBXLicenseIPC.h lucid/Authorization/LBXLicenseTransport.h
  lucid/Authorization/LBXLicenseExchange.h lucid/Authorization/LBXLicenseEndpoints.h
  lucid/Containers/LBXContainerConfigurationStore.h lucid/Containers/LBXContainerConfiguration.h lucid/Containers/LBXContainerEndpoints.h
  shared/RBXStorageGate.h daemon/RBXLicenseToken.h tests/RBXLicenseTestSupport.h)
shasum -a 256 "${proof_sources[@]}" > "$proof_evidence/source-before.sha256"
proof_flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -Idaemon -Ishared)
proof_definitions=(-DLBX_LICENSE_INSTALLATION_TESTING=1 -DLBX_LICENSE_VAULT_TESTING=1 -DLBX_CONTAINER_STORE_TESTING=1
  -DLBX_LICENSE_OWNER_TESTING=1 -DLBX_LICENSE_TRANSPORT_TESTING=1 -DLBX_LICENSE_EXCHANGE_TESTING=1)
xcrun clang "${proof_flags[@]}" "${proof_definitions[@]}" -framework Foundation -framework Security "${proof_units[@]}" -o "$proof_temporary/test" > "$proof_evidence/host-compile.log" 2>&1
"$proof_temporary/test" 2>&1 | tee "$proof_evidence/host.log"
xcrun clang "${proof_flags[@]}" -framework Foundation -framework Security "${proof_units[@]}" -o "$proof_temporary/production" > "$proof_evidence/production-compile.log" 2>&1
"$proof_temporary/production" 2>&1 | tee "$proof_evidence/production.log"
proof_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
for proof_arch in arm64 arm64e; do
  for proof_unit in Installation Store; do
    if [[ "$proof_unit" == Installation ]]; then proof_file=lucid/Authorization/LBXLicenseInstallationEstablishment.m; else proof_file=lucid/Containers/LBXContainerConfigurationStore.m; fi
    xcrun --sdk iphoneos clang -target "$proof_arch-apple-ios15.0" -isysroot "$proof_sdk" "${proof_flags[@]}" -c "$proof_file" -o "$proof_evidence/$proof_unit-$proof_arch.o" > "$proof_evidence/$proof_unit-$proof_arch.log" 2>&1
  done
done
python3 - "$proof_evidence" <<'PY' | tee "$proof_evidence/production-boundary.log"
import pathlib, sys
directory = pathlib.Path(sys.argv[1])
for arch in ('arm64','arm64e'):
    for unit in ('Installation','Store'):
        data=(directory/f'{unit}-{arch}.o').read_bytes()
        for marker in (b'testPreparePaths:',b'testOpenPaths:',b'testStopAfterBoundary:',b'testBoundaryHandler:',b'testPristineBoundaryHandler:',b'testStopPristineAfterBoundary:'):
            if marker in data:
                raise SystemExit(f'FAIL: test-only provider found in {unit} {arch}')
    print(f'PASS: production {arch} compilation and fixture boundary absence')
PY
shasum -a 256 "${proof_sources[@]}" > "$proof_evidence/source-after.sha256"
cmp "$proof_evidence/source-before.sha256" "$proof_evidence/source-after.sha256"
python3 - "$proof_evidence" <<'PY'
import pathlib, re, hashlib, json, sys
directory=pathlib.Path(sys.argv[1]);match=re.search(r'PASS: (\d+) source prepared-proof assertions, 0 failures',(directory/'host.log').read_text())
if not match:
    raise SystemExit('FAIL: no focused PASS result')
report={'status':'PASS','hostChecks':int(match.group(1)),'productionHostNonRootChecks':3,
        'productionArchitectures':['arm64','arm64e'],'sourceStable':True,
        'scope':'exact active-owner prepared proof consumption; no pending publication',
        'deviceExecution':'NOT_RUN','serviceIntegration':'NOT_RUN','freshCustomerInstall':'NOT_RUN','runtime':'NOT_RUN',
        'files':{path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in directory.iterdir() if path.is_file() and path.name!='result.json'}}
(directory/'result.json').write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
PY
