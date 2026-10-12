#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rbx-app-mdm.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -I"$ROOT/shared" -framework Foundation "$ROOT/tools/test_app_mdm.m" -o "$temporary/test"
"$temporary/test" "$temporary/output"

python3 - "$ROOT" "$temporary" <<'PYTHON'
import pathlib, shutil, subprocess, sys
root, temporary = map(pathlib.Path, sys.argv[1:])
for capability in (False, True):
    fixture = temporary / ("active" if capability else "inactive")
    for name in ("shared/RBXAppRegistry.h", "shared/RBXAppRegistryData.h", "launcher/RBXMDMExporter.h", "launcher/RBXMDMExporter.m", "tools/test_app_mdm.m"):
        destination = fixture / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, destination)
    registry = fixture / "shared/RBXAppRegistryData.h"
    original = registry.read_text()
    before, facebook = original.split('@"appType": @"facebook",', 1)
    import re
    facebook, count = re.subn(r'@"runnable": @(YES|NO),', '@"runnable": @' + ('YES' if capability else 'NO') + ',', facebook, count=1)
    assert count == 1
    registry.write_text(before + '@"appType": @"facebook",' + facebook)
    binary = fixture / "test"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-I" + str(fixture / "shared"), "-framework", "Foundation", str(fixture / "tools/test_app_mdm.m"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(fixture / "output")], check=True)
PYTHON
