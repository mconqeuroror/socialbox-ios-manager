#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-installation-build.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
test_evidence="${1:-$temporary/evidence}"
mkdir -p "$test_evidence"
chmod 700 "$test_evidence"
test_sources=(lucid/Authorization/LBXLicenseVault.h lucid/Authorization/LBXLicenseVault.m
  lucid/Containers/LBXContainerConfigurationStore.h lucid/Containers/LBXContainerConfigurationStore.m
  lucid/tests/installation_producer.m lucid/tests/test_installation_producer.sh)
shasum -a 256 "${test_sources[@]}" > "$test_evidence/source-before.sha256"
test_flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function -Idaemon -Ishared)
test_definitions=(-DLBX_CONTAINER_STORE_TESTING=1 -DLBX_LICENSE_OWNER_TESTING=1 -DLBX_LICENSE_VAULT_TESTING=1
  -DLBX_LICENSE_TRANSPORT_TESTING=1 -DLBX_LICENSE_EXCHANGE_TESTING=1)
test_units=(lucid/tests/installation_producer.m lucid/Containers/LBXContainerConfiguration.m
  lucid/Containers/LBXContainerConfigurationStore.m lucid/Authorization/LBXLicenseOwner.m
  lucid/Authorization/LBXLicenseIPC.m lucid/Authorization/LBXLicenseVault.m
  lucid/Authorization/LBXLicenseTransport.m lucid/Authorization/LBXLicenseExchange.m daemon/RBXLicenseToken.m)
xcrun clang "${test_flags[@]}" "${test_definitions[@]}" -framework Foundation -framework Security \
  "${test_units[@]}" -o "$temporary/test-installation-producer" > "$test_evidence/host-compile.log" 2>&1
"$temporary/test-installation-producer" 2>&1 | tee "$test_evidence/host.log"
xcrun clang "${test_flags[@]}" -framework Foundation -framework Security \
  "${test_units[@]}" -o "$temporary/production-roles" > "$test_evidence/production-host-compile.log" 2>&1
"$temporary/production-roles" 2>&1 | tee "$test_evidence/production-host.log"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
for test_arch in arm64 arm64e; do
  for test_unit in LicenseVault ContainerConfigurationStore; do
    if [[ "$test_unit" == LicenseVault ]]; then test_file=lucid/Authorization/LBXLicenseVault.m; else test_file=lucid/Containers/LBXContainerConfigurationStore.m; fi
    xcrun --sdk iphoneos clang -target "$test_arch-apple-ios15.0" -isysroot "$sdk" "${test_flags[@]}" \
      -c "$test_file" -o "$test_evidence/$test_unit-$test_arch.o" > "$test_evidence/$test_unit-$test_arch-compile.log" 2>&1
  done
done
python3 - "$test_evidence" <<'PY' | tee "$test_evidence/production-boundary.log"
import pathlib, sys
directory = pathlib.Path(sys.argv[1])
for arch in ('arm64', 'arm64e'):
    for unit in ('LicenseVault', 'ContainerConfigurationStore'):
        data = (directory / f'{unit}-{arch}.o').read_bytes()
        for marker in (b'testPristineBoundaryHandler:', b'testStopPristineAfterBoundary:', b'PristineStopBoundary', b'PristineBoundaryHandler'):
            if marker in data:
                raise SystemExit(f'FAIL: test-only pristine seam found in production {unit} {arch}')
    print(f'PASS: production {arch} compilation and pristine test-seam absence')
PY
shasum -a 256 "${test_sources[@]}" > "$test_evidence/source-after.sha256"
cmp "$test_evidence/source-before.sha256" "$test_evidence/source-after.sha256"
python3 - "$test_evidence" <<'PY'
import hashlib, json, pathlib, re, sys
directory = pathlib.Path(sys.argv[1])
line = (directory / 'host.log').read_text()
match = re.search(r'PASS: (\d+) installer prerequisite assertions, 0 failures', line)
if not match:
    raise SystemExit('FAIL: focused result not PASS')
report = {'status':'PASS', 'hostChecks':int(match.group(1)), 'productionNonRootChecks':5,
          'sourceStable':True, 'productionArchitectures':['arm64','arm64e'],
          'scope':'pristine creation and non-grant local installation observations only',
          'physicalDevice':'NOT_RUN', 'installerEstablishment':'NOT_RUN',
          'freshCustomerInstallation':'NOT_RUN', 'runtime':'NOT_RUN',
          'files':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.iterdir()
                   if p.is_file() and p.name != 'result.json'}}
(directory / 'result.json').write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
PY
