#!/usr/bin/env python3
"""Run real Objective-C runtime contract/shape tests without loading SocialBox."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "lucid/Diagnostics/LBXRecoveredContextAdapter.m"
FIXTURE = ROOT / "lucid/tests/recovered_context_adapter.m"

def main() -> None:
    results = []
    with tempfile.TemporaryDirectory(prefix="lbx-recovered-context-") as directory:
        for variant in ("normal", "LBX_WRONG_CONTROLLER_SIGNATURE", "LBX_WRONG_ROW_SIGNATURE"):
            output = Path(directory) / variant
            command = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
                       "-Wno-unused-parameter", "-Wno-unused-function", "-DLBX_RECOVERED_CONTEXT_TESTING=1",
                       "-framework", "Foundation", str(SOURCE), str(FIXTURE), "-o", str(output)]
            if variant != "normal":
                command.insert(2, f"-D{variant}=1")
            subprocess.run(command, check=True)
            completed = subprocess.run([str(output)], check=True, text=True, capture_output=True)
            results.append({"variant": variant, **json.loads(completed.stdout)})
        # The production translation unit must also compile without the test seam.
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-c",
                        str(SOURCE), "-o", str(Path(directory) / "production.o")], check=True)
    print(json.dumps({"suite": "recovered_context_adapter", "checks": sum(r["checks"] for r in results),
                      "failures": sum(r["failures"] for r in results), "variants": results}))

if __name__ == "__main__":
    main()
