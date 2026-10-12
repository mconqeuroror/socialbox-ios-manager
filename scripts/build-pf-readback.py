#!/usr/bin/env python3
"""Build the non-shipping, read-only PF diagnostic for a private device test.

Requires Procursus ldid. Does not install, SSH, change PF, or publish a package.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ["experimental/pf/RBXPFPolicyPlan.m", "experimental/pf/RBXPFKernelPolicy.m",
           "tools/pf_policy_readback.m"]
INPUTS = SOURCES + ["experimental/pf/RBXPFPolicyPlan.h", "experimental/pf/RBXPFKernelPolicy.h",
                   "experimental/pf/RBXPFKernelABI.h", "scripts/build-pf-readback.py"]


def run(*args):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace")[:4000] or "Tool failed")
    return result.stdout


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ldid", type=Path, required=True)
    args = parser.parse_args()
    output, ldid = args.output.resolve(), args.ldid.resolve()
    if output.is_relative_to(ROOT):
        raise RuntimeError("Diagnostic output must remain outside the repository")
    before = {name: digest(ROOT / name) for name in INPUTS}
    signer_digest = digest(ldid)
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    entitlements = output / "empty-entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({}))
    binaries = {}
    for arch in ("arm64", "arm64e"):
        binary = output / ("socialbox-pf-readback-" + arch)
        run("xcrun", "--sdk", "iphoneos", "clang", "-target", arch + "-apple-ios15.0",
            "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror", "-Iexperimental/pf",
            "-framework", "Foundation", *SOURCES, "-o", binary)
        run(ldid, "-Cadhoc", "-S" + str(entitlements), binary)
        if plistlib.loads(run(ldid, "-e", binary)) != {}:
            raise RuntimeError("Unexpected diagnostic entitlements")
        run("/usr/bin/codesign", "--verify", "--strict", binary)
        run("xcrun", "lipo", binary, "-verify_arch", arch)
        binaries[arch] = {"file": binary.name, "size": binary.stat().st_size,
                          "sha256": digest(binary), "codeSignatureVerified": True, "entitlements": {}}
    if before != {name: digest(ROOT / name) for name in INPUTS} or signer_digest != digest(ldid):
        raise RuntimeError("Inputs changed during compilation")
    report = {"schemaVersion": 1, "kind": "pf-read-only-policy-readback", "sourceSHA256": before,
              "signerSHA256": signer_digest, "binaries": binaries,
              "reviewedDeviceKernel": {"model": "iPhone10,6", "release": "22.6.0",
                                        "xnu": "8796.142.1.703.8", "architecture": "ARM64_T8015"},
              "readOnly": True, "enforcementVerified": False, "applicationAdmissionAllowed": False,
              "deviceExecution": "NOT_RUN", "ruleInstallation": "NOT_IMPLEMENTED"}
    (output / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("kind", "binaries", "deviceExecution")}, indent=2))


if __name__ == "__main__":
    main()
