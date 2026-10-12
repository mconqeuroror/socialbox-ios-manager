#!/usr/bin/env python3
"""Build the source-owned root license service or a private acceptance pair.

The manager consumer uses the reviewed app path/hash and fixed production
endpoint. Neither mode implements retained-engine admission.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import subprocess
import tempfile
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMMON = ["lucid/Authorization/LBXLicenseIPC.m", "lucid/Authorization/LBXLicensePeer.m", "lucid/HelperSafety/LBXCallerFile.m"]
CLIENT = COMMON + ["lucid/Authorization/LBXLicenseClient.m", "lucid/Authorization/ClientProbe.m",
    "lucid/Containers/LBXContainerMutationClient.m", "lucid/Containers/LBXContainerMutationIPC.m",
    "lucid/Containers/LBXContainerConfiguration.m"]
SERVICE = COMMON + ["lucid/Authorization/LicenseService.m", "lucid/Authorization/LBXLicenseOwner.m",
                    "lucid/Authorization/LBXLicenseInstallationEstablishment.m",
                    "lucid/Authorization/LBXLicenseVault.m", "lucid/Authorization/LBXLicenseTransport.m",
                    "lucid/Authorization/LBXLicenseExchange.m", "daemon/RBXLicenseToken.m",
                    "lucid/Containers/LBXContainerIPC.m", "lucid/Containers/LBXContainerMutationIPC.m",
                    "lucid/Containers/LBXContainerRootPendingStore.m", "lucid/Containers/LBXContainerRootMutationOwner.m",
                    "lucid/Containers/LBXContainerConfiguration.m", "lucid/Containers/LBXContainerConfigurationStore.m"]
INSTALLER = [name for name in SERVICE if name != "lucid/Authorization/LicenseService.m"] + ["lucid/Authorization/InstallPreparation.m"]
PROGRAM_IDENTIFIERS = {
    "client": "com.socialbox.licensing.client",
    "service": "com.socialbox.licensing.owner",
    "installer": "com.socialbox.licensing.preparation",
}


def run(*args):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace")[:4000] or "Build failed")
    return result.stdout


def verify_program_signature(binary, name, ldid):
    """Host integrity/role consistency only; no publisher or device trust."""
    if name not in PROGRAM_IDENTIFIERS:
        raise RuntimeError("Unknown fixed program signing role")
    identity = PROGRAM_IDENTIFIERS[name]
    architectures = run("xcrun", "lipo", "-archs", binary).decode().split()
    if len(architectures) != 2 or set(architectures) != {"arm64", "arm64e"}:
        raise RuntimeError("Signed program must contain exactly arm64 and arm64e")
    requirement = '=identifier "' + identity + '"'
    run("/usr/bin/codesign", "--verify", "--strict", "--all-architectures",
        "--test-requirement", requirement, binary)
    # ldid's default extraction can observe only one architecture. Check both
    # final signed slices; neither may carry an entitlement authority claim.
    with tempfile.TemporaryDirectory(prefix=".signed-program-", dir=binary.parent) as directory:
        for arch in ("arm64", "arm64e"):
            thin = Path(directory) / arch
            run("xcrun", "lipo", binary, "-thin", arch, "-output", thin)
            run("/usr/bin/codesign", "--verify", "--strict", "--test-requirement", requirement, thin)
            if run(ldid, "-e", thin).strip():
                raise RuntimeError("Unexpected signed program entitlement: " + arch)


def sign_program(binary, name, ldid):
    if name not in PROGRAM_IDENTIFIERS:
        raise RuntimeError("Unknown fixed program signing role")
    identity = PROGRAM_IDENTIFIERS[name]
    # Sign the final universal bytes, before their digest is used for a client
    # pin or a report. Thin ldid signatures alone fail strict arm64e host checks.
    run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
        "--identifier", identity, "--requirements", '=designated => identifier "' + identity + '"', binary)
    verify_program_signature(binary, name, ldid)


def snapshot():
    pending = set(CLIENT + SERVICE + INSTALLER + ["scripts/build-socialbox-license-service.py", "scripts/license-key.py"])
    hashes = {}
    while pending:
        name = pending.pop()
        path = ROOT / name
        if not path.is_file() or path.resolve() != path or not path.is_relative_to(ROOT):
            raise RuntimeError("Missing or aliased source input: " + name)
        data = path.read_bytes()
        hashes[name] = hashlib.sha256(data).hexdigest()
        if path.suffix in (".h", ".m"):
            for target in re.findall(r'^\s*#\s*(?:import|include)\s*"([^"\n]+)"', data.decode(), re.M):
                candidates = [path.parent / target, ROOT / "daemon" / target, ROOT / "shared" / target]
                dependency = next((Path(os.path.abspath(value)) for value in candidates if value.is_file()), candidates[0])
                if not dependency.is_relative_to(ROOT):
                    raise RuntimeError("Escaping source dependency")
                relative = str(dependency.relative_to(ROOT))
                if relative not in hashes:
                    pending.add(relative)
    return dict(sorted(hashes.items()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public-key", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ldid", type=Path, required=True)
    parser.add_argument("--openssl", default="openssl")
    parser.add_argument("--consumer", choices=("acceptance", "manager"), default="acceptance")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.is_relative_to(ROOT):
        raise RuntimeError("Acceptance output must be private and outside the repository")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    before = snapshot()
    manager = args.consumer == "manager"
    instance = uuid.uuid4().hex
    directory = "/var/jb/var/lib/socialbox-license-acceptance-" + instance
    endpoint = "com.socialbox.license.acceptance." + instance
    service_path, client_path, installer_path = directory + "/service", directory + "/client", directory + "/installer"
    if manager:
        # Resolve only literal reviewed build-time values. Never accept a
        # runtime caller-selected endpoint or expand arbitrary preprocessor code.
        configuration = (ROOT / "lucid/Authorization/LBXLicenseEndpoints.h").read_text()
        def value(name):
            matches = re.findall(r'^#define ' + name + r' "([^"\n]+)"$', configuration, re.M)
            if len(matches) != 1:
                raise RuntimeError("Ambiguous manager endpoint: " + name)
            return matches[0]
        endpoint = value("LBX_LICENSE_SERVICE_NAME")
        service_path = value("LBX_LICENSE_SERVICE_PATH")
        installer_path = value("LBX_LICENSE_INSTALLER_PATH")
        client_path = value("LBX_LICENSE_CLIENT_PATH")
        directory = value("LBX_LICENSE_VAULT_PATH")
    pin = output / "public-pin.h"
    spec = importlib.util.spec_from_file_location("license_key", ROOT / "scripts/license-key.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    kid = module.pin(args.public_key.resolve(), pin, args.openssl)
    header = output / "owner-config.h"
    header.write_text("// Reviewed manager defaults are imported by each translation unit.\n" if manager else "\n".join("#define " + key + " " + json.dumps(value) for key, value in {
        "LBX_LICENSE_SERVICE_NAME": endpoint, "LBX_LICENSE_SERVICE_PATH": service_path,
        "LBX_LICENSE_VAULT_PATH": directory + "/pairing", "LBX_LICENSE_CLIENT_PATH": client_path,
        "LBX_CONTAINER_STORE_PATH": directory + "/configurations",
        "LBX_CONTAINER_PENDING_PATH": directory + "/pending",
        "LBX_LICENSE_INSTALLATION_PATH": directory + "/installation",
        "LBX_LICENSE_INSTALLER_PATH": installer_path,
    }.items()) + "\n")
    def build(name, sources):
        slices = []
        for arch in ("arm64", "arm64e"):
            thin = output / (name + "-" + arch)
            run("xcrun", "--sdk", "iphoneos", "clang", "-target", arch + "-apple-ios15.0",
                "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations",
                "-Idaemon", "-Ishared", "-include", pin, "-include", header,
                "-framework", "Foundation", "-framework", "Security", *sources, "-o", thin)
            run(args.ldid.resolve(), "-S", thin)
            if run(args.ldid.resolve(), "-e", thin).strip():
                raise RuntimeError("Unexpected acceptance entitlement")
            slices.append(thin)
        binary = output / name
        run("xcrun", "lipo", "-create", *slices, "-output", binary)
        sign_program(binary, name, args.ldid.resolve())
        data = binary.read_bytes()
        if any(marker in data for marker in (b"testUseProtocol:", b"testUsePublicKey:", b"testUseAuthorizationClock:",
                b"testStopAfterBoundary:", b"testStopEstablishmentAfterBoundary:", b"testStartWithConfiguration:", b"testExchangeWithConfiguration:",
                b"testPreparePaths:clientSHA256:size:error:", b"testOpenPaths:clientSHA256:size:error:",
                b"testPristineBoundaryHandler:", b"testStopPristineAfterBoundary:",
                b"testBoundaryHandler:",
                b"LBXLicenseInstallPeerFixture", b"LBXContainerMutationInstallClientFixture")):
            raise RuntimeError("Test seam in executable")
        return {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}

    client = None
    if manager:
        size_matches=re.findall(r'^#define LBX_LICENSE_CLIENT_SIZE ([1-9][0-9]*)$',configuration,re.M)
        digest=value("LBX_LICENSE_CLIENT_SHA256")
        if len(size_matches)!=1 or not re.fullmatch(r'[a-f0-9]{64}',digest):
            raise RuntimeError("Malformed reviewed manager pin")
        client={"sha256":digest,"size":int(size_matches[0]),"source":"reviewed manager executable; not rebuilt"}
    if not manager:
        client = build("client", CLIENT)
        with header.open("a") as handle:
            handle.write('#define LBX_LICENSE_CLIENT_SHA256 "' + client["sha256"] + '"\n')
            handle.write("#define LBX_LICENSE_CLIENT_SIZE " + str(client["size"]) + "\n")
    service = build("service", SERVICE)
    installer = build("installer", INSTALLER)
    launchd = {"Label": endpoint, "Program": service_path, "MachServices": {endpoint: True},
               "UserName": "root", "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10,
               "ProcessType": "Interactive"}
    plist = plistlib.dumps(launchd, sort_keys=True)
    (output / "service.plist").write_bytes(plist)
    if before != snapshot():
        raise RuntimeError("Source changed during compilation")
    report = {"kind": "manager-license-owner-candidate" if manager else "private-license-owner-ipc-acceptance", "schemaVersion": 1, "keyId": kid,
              "remoteDirectory": directory, "serviceName": endpoint, "servicePath": service_path,
              "clientPath": client_path, "installerPath": installer_path, "minimumIOS": "15.0",
              "architectures": ["arm64", "arm64e"], "client": client, "service": service, "installer": installer,
              "launchdSHA256": hashlib.sha256(plist).hexdigest(), "sourceSHA256": before,
              "configSHA256": hashlib.sha256(header.read_bytes()).hexdigest(), "entitlements": {},
              "retainedAppUpdated": False, "retainedEngineIntegrated": False, "deviceExecution": "NOT_RUN",
              "pendingBootstrap": "No bootstrap RPC; typed prepared pending establishment follows genuine activation/validation under the original source deadline",
              "freshInstallReady": False, "customerDeliveryReady": False,
              "initialization": "Explicit fixed root installer prepare command only; no-argument/unknown commands refuse. Separate check opens existing prepared state only; partial state stays closed. Command intent is not independent first-install authority/history",
              "pairedPendingEstablishment": "Typed one-shot prepared proof consumed inside held-empty namespace after genuine activation/validation under original deadline",
              "installationPolicy": "Ordinary startup requires complete current prepared provenance; missing state has no fallback",
              "acceptanceCaller": "real UID 501 only; invoking the acceptance client as real UID 0 is denied",
              "managerAuditRole": "real UID 501 and effective UID 0 or 501; fixed executable pin",
              "legacyConfigurationMutations": "DENIED; only read/list through paired pending context"}
    report["signatures"] = {
        "kind": "macOS verified ad-hoc signatures; no publisher/device trust",
        "programs": {name: {"identifier": PROGRAM_IDENTIFIERS[name],
                            "strictAllArchitectures": "PASS", "explicitIdentifierRequirement": "PASS",
                            "arm64EntitlementsEmpty": "PASS", "arm64eEntitlementsEmpty": "PASS"}
                     for name in (("service", "installer") if manager else ("client", "service", "installer"))},
        "imageMigration": "Unsupported; new bytes cannot replace established prepared image policy",
    }
    (output / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("kind", "architectures", "client", "service", "installer")}, indent=2))


if __name__ == "__main__":
    main()
