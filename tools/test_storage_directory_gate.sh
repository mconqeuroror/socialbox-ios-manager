#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-directory-gate.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
xcrun clang -x c -Wall -Wextra -Werror -fsyntax-only -include "$ROOT/shared/RBXStorageGate.h" /dev/null
xcrun clang++ -x c++ -std=c++17 -Wall -Wextra -Werror -fsyntax-only -include "$ROOT/shared/RBXStorageGate.h" /dev/null
xcrun clang -Wall -Wextra -Werror -I"$ROOT/shared" "$ROOT/tools/test_storage_directory_gate.c" -o "$temporary/test"
mkdir "$temporary/homes"
"$temporary/test" "$temporary/homes"
python3 - "$ROOT" "$temporary" <<'PY'
from pathlib import Path
import subprocess
import sys

root, temporary = map(Path, sys.argv[1:])
source = (root / "shared/RBXStorageGate.h").read_text()
mutants = {
    "first-root-only": (
        "for(size_t i=0;i<selectedCount;i++) {\n        if(!authorized||!authorized(context))",
        "for(size_t i=0;i<selectedCount&&i<1;i++) {\n        if(!authorized||!authorized(context))"),
    "missing-reseal": (
        "reseal:\n    RBXStorageGateSealDirectories(pins,count,rootOwner,rootGroup);",
        "reseal:\n    ;"),
    "immutable-first-root-only": (
        "selectedIndex<selectedCount;selectedIndex++",
        "selectedIndex<selectedCount&&selectedIndex<1;selectedIndex++"),
    "immutable-missing-reseal": (
        "immutable_reseal:\n    RBXStorageGateImmutableFreezeAll(frozen,count,rootOwner,rootGroup,appOwner);",
        "immutable_reseal:\n    ;"),
    "node-first-root-only": (
        "for(size_t pick=0;pick<selectedCount;pick++)",
        "for(size_t pick=0;pick<selectedCount&&pick<1;pick++)"),
    "node-missing-reseal": (
        "node_reseal:\n    RBXStorageGateNodesFreezeAll(nodes,count,rootOwner,rootGroup,appOwner);",
        "node_reseal:\n    ;"),
    "node-allows-hardlink": (
        "(!S_ISREG(node->st_mode)||node->st_nlink!=1)",
        "(!S_ISREG(node->st_mode))"),
}
for name, (before, after) in mutants.items():
    if source.count(before) != 1:
        raise SystemExit("Cannot locate exact directory-gate regression mutation")
    directory = temporary / name
    directory.mkdir()
    (directory / "RBXStorageGate.h").write_text(source.replace(before, after))
    (directory / "homes").mkdir()
    subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-I" + str(directory),
                    str(root / "tools/test_storage_directory_gate.c"), "-o", str(directory / "test")], check=True)
    result = subprocess.run([str(directory / "test"), str(directory / "homes")], capture_output=True, text=True)
    if result.returncode != 1 or not result.stderr.startswith("FAIL line "):
        raise SystemExit("Directory-gate fixture failed to reject " + name)
    print("PASS directory-gate regression rejects " + name)
PY
