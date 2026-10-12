#!/usr/bin/env python3
"""Build a public-key-pinned standalone licensing acceptance tool, not an app update."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ["lucid/Authorization/LBXLicenseTransport.m",
           "lucid/Authorization/LBXLicenseExchange.m", "daemon/RBXLicenseToken.m"]


def run(*args):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace")[:2000] or "Build tool failed")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public-key", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ldid", type=Path, required=True)
    parser.add_argument("--openssl", default="openssl")
    parser.add_argument("--entrypoint", choices=("exchange", "vault"), default="exchange")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    pin = output / "license-public-pin.h"
    import importlib.util
    spec = importlib.util.spec_from_file_location("license_key", ROOT / "scripts/license-key.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    kid = module.pin(args.public_key.resolve(), pin, args.openssl)
    sources = SOURCES + (["lucid/Authorization/VaultProbe.m", "lucid/Authorization/LBXLicenseVault.m"]
                         if args.entrypoint == "vault" else ["lucid/Authorization/Probe.m"])
    inputs = sources + ["lucid/Authorization/LBXLicenseTransport.h", "lucid/Authorization/LBXLicenseExchange.h",
                        "daemon/RBXLicenseToken.h", "shared/RBXLicensePin.h", "scripts/license-key.py", str(Path(__file__).relative_to(ROOT))]
    if args.entrypoint == "vault":
        inputs.append("lucid/Authorization/LBXLicenseVault.h")
    before = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in inputs}
    slices = []
    for arch in ("arm64", "arm64e"):
        binary = output / ("probe-" + arch)
        run("xcrun", "--sdk", "iphoneos", "clang", "-target", arch + "-apple-ios15.0",
            "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror", "-Idaemon", "-Ishared",
            "-include", pin, "-framework", "Foundation", "-framework", "Security", *sources, "-o", binary)
        slices.append(binary)
    binary = output / ("socialbox-license-vault-probe" if args.entrypoint == "vault" else "socialbox-license-probe")
    run("xcrun", "lipo", "-create", *slices, "-output", binary)
    run(args.ldid.resolve(), "-S", binary)
    if run(args.ldid.resolve(), "-e", binary).strip():
        raise RuntimeError("Acceptance tool must not acquire extra entitlements")
    data = binary.read_bytes()
    if any(marker in data for marker in (b"testStartWithConfiguration:", b"testExchangeWithConfiguration:", b"testUsePublicKey:")):
        raise RuntimeError("Test override found in production acceptance binary")
    if before != {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in inputs}:
        raise RuntimeError("Source changed during compilation")
    report = {"schemaVersion": 1, "kind": "standalone-license-acceptance", "entrypoint": args.entrypoint, "keyId": kid,
              "architectures": ["arm64", "arm64e"], "minimumIOS": "15.0",
              "sha256": hashlib.sha256(data).hexdigest(), "sourceSHA256": before,
              "entitlements": {}, "retainedEngineIntegration": False,
              "deviceExecution": "NOT_RUN", "credentialsInReport": False}
    (output / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
