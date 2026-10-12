#!/usr/bin/env python3
"""Build a PRIVATE, unvalidated, upgrade-only owner-base SocialBox candidate.

This does not install anything, execute imported maintainer scripts, modify the
original programs, migrate a license, or assert runtime isolation. The reviewed
handoff must already be installed unchanged. Run the emitted read-only preflight
BEFORE dpkg: an old package's prerm can run before the incoming preinst.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import struct
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import recover_socialbox_base as recovery
from enumerate_leak_binary import MAGICS, MachO, checked, macho_slices, sha

PACKAGE = "com.socialbox"
BASE_VERSION = "3.1.0-1"
VERSION = "3.1.0-1+socialbox.2"
APP = "var/jb/Applications/SocialBox.app/"
INFO = APP + "Info.plist"
BINARY = APP + "SocialBox"
OVERLAY = "var/jb/Library/MobileSubstrate/DynamicLibraries/LBXPresentation.dylib"
FILTER = OVERLAY.removesuffix(".dylib") + ".plist"
ICON_NAMES = ("SocialBoxIcon60@2x.png", "SocialBoxIcon60@3x.png")
ADDED_PATHS = {OVERLAY, FILTER, *(APP + name for name in ICON_NAMES)}
INFO_COPY = {
    "CFBundleName": "SocialBox",
    "NSLocationWhenInUseUsageDescription": "SocialBox uses your location to show your position on the map.",
    "NSLocationAlwaysAndWhenInUseUsageDescription": "SocialBox uses location access for location simulation.",
    "NSCameraUsageDescription": "SocialBox uses the camera to scan proxy QR codes.",
    "NSLocalNetworkUsageDescription": "SocialBox uses your local network for server communication, container sync and proxy connections.",
    "NSPhotoLibraryUsageDescription": "SocialBox imports a photo you select for optional camera tools.",
}
INFO_KEYS = {"CFBundleDisplayName", "CFBundleIconFile", "CFBundleIconFiles", "CFBundleIcons", "SocialBoxBuild", "CFBundleDocumentTypes", "UTExportedTypeDeclarations", *INFO_COPY}
EXTENSION_COPY = {
    APP + "PlugIns/SocialBoxFilesProvider.appex/Info.plist": "SocialBox Exports",
    APP + "PlugIns/SocialBoxPacketTunnel.appex/Info.plist": "SocialBox VPN",
}


def presentation_paths(baseline):
    return {INFO} | (set(EXTENSION_COPY) & set(baseline))


def extension_metadata(info, label):
    # Only the two system-facing names change. The extension identity,
    # executable, principal class, entitlements and routing remain original.
    return dict(info, CFBundleName=label, CFBundleDisplayName=label)


def display_metadata(info):
    result = dict(info)
    for key, value in INFO_COPY.items():
        if key in info:
            result[key] = value
    if "CFBundleDocumentTypes" in info:
        require(isinstance(info["CFBundleDocumentTypes"], list), "Unexpected document metadata")
        result["CFBundleDocumentTypes"] = [dict(item, CFBundleTypeName="SocialBox Container")
            if item.get("CFBundleTypeName") == "SocialBox Container" else dict(item)
            for item in info["CFBundleDocumentTypes"]]
    if "UTExportedTypeDeclarations" in info:
        declarations = info["UTExportedTypeDeclarations"]
        require(isinstance(declarations, list) and all(isinstance(item, dict) for item in declarations),
                "Unexpected archive type metadata")
        descriptions = {"SocialBox Container Archive": "SocialBox Container Archive",
                        "SocialBox Container Archive (legacy)": "SocialBox Container Archive (legacy)"}
        # These are system-facing labels, not format identifiers. Preserve all
        # original UTIs, extension tags, conformance and unrelated descriptions.
        result["UTExportedTypeDeclarations"] = [
            dict(item, UTTypeDescription=descriptions[item["UTTypeDescription"]])
            if item.get("UTTypeDescription") in descriptions else dict(item)
            for item in declarations]
    return result

SERVICES = ("com.socialboxhelper", "com.secretsauce.secretsauced", "com.secretsauce.secretsaucemonitor")
BACKUP_DIRECTORY = "/var/jb/var/lib/socialbox-upgrade"
BACKUP_PATH = BACKUP_DIRECTORY + "/original-3.1.0-1-postinst"
require = recovery.require
PRODUCTION_GROUPS = ("Presentation", "Diagnostics", "ProxyInput")
LICENSE_CLIENT_SOURCES = ["lucid/Authorization/LBXLicenseClient.m", "lucid/Authorization/LBXLicenseIPC.m", "lucid/Authorization/LBXLicensePeer.m", "lucid/HelperSafety/LBXCallerFile.m",
                        "lucid/Containers/LBXContainerClient.m", "lucid/Containers/LBXContainerIPC.m", "lucid/Containers/LBXContainerConfiguration.m",
                        "lucid/Containers/LBXContainerPendingMutation.m", "lucid/Containers/LBXContainerMutationCoordinator.m",
                        "lucid/Containers/LBXContainerMutationClient.m", "lucid/Containers/LBXContainerMutationIPC.m",
                        "lucid/Containers/LBXContainerRootMutationCoordinator.m"]
PRODUCTION_SOURCE_EXPRESSION = "$(wildcard Presentation/*.m) $(wildcard Diagnostics/*.m) $(wildcard ProxyInput/*.m) ../shared/RBXHTTPProxy.m Authorization/LBXLicenseClient.m Authorization/LBXLicenseIPC.m Authorization/LBXLicensePeer.m HelperSafety/LBXCallerFile.m Containers/LBXContainerClient.m Containers/LBXContainerIPC.m Containers/LBXContainerConfiguration.m Containers/LBXContainerPendingMutation.m Containers/LBXContainerMutationCoordinator.m Containers/LBXContainerMutationClient.m Containers/LBXContainerMutationIPC.m Containers/LBXContainerRootMutationCoordinator.m"
REQUIRED_OVERLAY_EXPORTS = frozenset({
    "LBXPlanProxyInput", "LBXDispatchProxyInput", "RBXParseHTTPProxyURL", "LBXPresentationInstall",
    "LBXPresentationStatus", "LBXPresentationMetadataSupported", "LBXRecoveredContextSnapshot",
    "SBSwitchProgressInstall",
    "LBXIsolationAssessment", "LBXIsolationPublicReport", "LBXWorkspaceApply", "LBXWorkspaceRefresh", "LBXWorkspaceStatus", "LBXDisplayCopy",
    "SBPresentSavedContainerSetups", "SBSavedContainerSetupEntryTitle",
    "LBXSendContainerMutationRequest", "LBXContainerMutationIPCValidateRequest", "LBXContainerMutationIPCValidateReply",
})
PROXY_HOOK_MARKER = b"LBX_PROXY_INPUT unsupported host/method; original handler retained"
FORBIDDEN_OVERLAY_SEAMS = ("LBXInstallProxyInputFixture", "LBXPresentationFixtureMetadata",
                           "SBSwitchProgressFixtureReduceMotion",
                           "LBXPresentationApplyFixture", "LBXRecoveredContextSnapshotForTesting", "LBXLicenseExchange",
                           "testUseHomeDirectory:clientExecutable:", "testStopAfterBoundary:",
                           "testUseLicenseSender:containerSender:", "testStopJournalAfterBoundary:",
                           "testUseLicenseSender:mutationSender:", "testUseStepBudget:")


def production_input_snapshot(root=None):
    """Snapshot reviewed production TUs and their quoted project headers.

    This is separate from the historical all-lucid snapshot, which includes
    tests and intentionally unlinked research. System SDK/Theos headers are not
    claimed as source-owned inputs. Changed Makefile source selection requires
    an explicit update here rather than silently treating research as shipped.
    """
    root = (root or ROOT).resolve()
    hashes = {}

    def read(path, kind):
        require(path.is_relative_to(root) and path.resolve() == path and path.is_file(),
                "Missing, aliased or escaping production " + kind + ": " + str(path))
        raw = path.read_bytes()
        hashes[str(path.relative_to(root))] = sha(raw)
        return raw

    makefile = read(root / "lucid/Makefile", "Makefile").decode("utf-8")
    assignments = re.findall(r"(?m)^\s*(?:(?:override|export)\s+)?LBXPresentation_FILES\s*(?::=|\+=|\?=|=)\s*(.*)$", makefile)
    require(assignments == [PRODUCTION_SOURCE_EXPRESSION], "Unreviewed production source assignment")
    read(root / "lucid/LBXPresentation.plist", "filter")
    units = sorted([p for group in PRODUCTION_GROUPS for p in (root / "lucid" / group).glob("*.m")]
                   + [root / "shared/RBXHTTPProxy.m"] + [root / name for name in LICENSE_CLIENT_SOURCES])
    require(all(any(p.parent == root / "lucid" / group for p in units) for group in PRODUCTION_GROUPS),
            "Missing production source group")
    headers, pending, visited = set(), list(units), set()
    include_dirs = [root / "lucid" / group for group in PRODUCTION_GROUPS]
    while pending:
        path = pending.pop()
        if path in visited:
            continue
        visited.add(path)
        source = read(path, "source" if path in units else "header").decode("utf-8")
        for name in re.findall(r'^\s*#\s*(?:import|include)\s*"([^"\n]+)"', source, re.MULTILINE):
            candidates = [path.parent / name, *(directory / name for directory in include_dirs)]
            header = next((p for p in candidates if p.is_file()), candidates[0])
            # Normalize dot components, but reject symlinks and paths outside
            # the repository before reading any bytes.
            header = Path(os.path.abspath(header))
            require(header.suffix == ".h", "Unsupported production project header: " + name)
            read(header, "header")
            headers.add(header)
            pending.append(header)
    return {"translation_units": [str(p.relative_to(root)) for p in units],
            "project_headers": sorted(str(p.relative_to(root)) for p in headers),
            "sha256": dict(sorted(hashes.items()))}


def require_unchanged_inputs(before, root=None):
    try:
        after = production_input_snapshot(root)
    except (ValueError, OSError, UnicodeError) as error:
        raise ValueError("Production inputs changed during build: " + str(error)) from error
    require(before == after, "Production inputs changed during build; discard output and rebuild")
    return before


def validate_linked_overlay(path, raw):
    """Inspect our compiled output only; never load or execute the dylib."""
    require(path.read_bytes() == raw, "Overlay changed before linked-output validation")
    slices = {}
    for _, part in macho_slices(raw):
        macho = MachO(part)
        architecture = {0: "arm64", 2: "arm64e"}.get(macho.subtype & 0xffffff)
        require(macho.cpu == 0x100000c and architecture and architecture not in slices,
                "Unexpected linked-output architecture")
        slices[architecture] = part
    require(set(slices) == {"arm64", "arm64e"}, "Linked output needs both architectures")
    result = []
    for architecture in ("arm64", "arm64e"):
        part = slices[architecture]
        require(PROXY_HOOK_MARKER in part, "Missing production proxy hook marker in " + architecture)
        require(not any(name.encode() in part for name in FORBIDDEN_OVERLAY_SEAMS),
                "Fixture/testing or unlinked authorization seam in " + architecture)
        output = subprocess.run(["xcrun", "nm", "-arch", architecture, "-gU", str(path)],
                                check=True, capture_output=True, text=True).stdout
        symbols = {}
        for line in output.splitlines():
            if not line.strip() or line.rstrip().endswith(":"):
                continue
            match = re.fullmatch(r"\s*[0-9a-fA-F]+\s+([A-Za-z])\s+(\S+)\s*", line)
            require(match is not None, "Unrecognized nm output for " + architecture)
            symbols[match[2]] = match[1]
        require(all(symbols.get("_" + name) == "T" for name in REQUIRED_OVERLAY_EXPORTS),
                "Missing production proxy/presentation/context exports in " + architecture)
        require(symbols.get("_OBJC_CLASS_$_LBXContainerRootMutationCoordinator") in ("S", "D"),
                "Missing production root saved-setup coordinator class in " + architecture)
        require(not any(marker in symbol.lower() for symbol in symbols
                        for marker in ("fixture", "testing", "lbxlicenseexchange")),
                "Fixture/testing or unlinked authorization export in " + architecture)
        result.append({"architecture": architecture, "slice_sha256": sha(part),
                       "required_exports": sorted(REQUIRED_OVERLAY_EXPORTS),
                       "exported_symbols": sorted(symbols), "proxy_hook_marker_present": True,
                       "forbidden_test_and_authorization_seams_present": False})
    require(path.read_bytes() == raw, "Overlay changed during linked-output validation")
    return result


def load_handoff(path):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 256 * 1024 ** 2,
            "Expected bounded regular handoff ZIP")
    raw = path.read_bytes()
    require(sha(raw) == recovery.HANDOFF_SHA256, "Handoff hash differs from reviewed input")
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        manifest, files = recovery.verify_layout(archive)
        payload = {n.removeprefix("compiled/"): b for n, b in files.items() if n.startswith("compiled/")}
        modes = {n: (archive.getinfo(recovery.PREFIX + "compiled/" + n).external_attr >> 16) & 0o777
                 for n in payload}
        require(all(modes.values()), "Missing baseline mode")
        fields = dict(line.split("=", 1) for line in archive.read(recovery.PREFIX + "metadata/package-control.txt")
                      .decode().splitlines() if "=" in line)
    return manifest, files, payload, modes, fields


def resource_bindings(raw):
    """Require this exact baseline's unsealed Info/resources in EVERY CD/slice.

    We never re-sign an original. Nonzero Info or resource special slots, an
    unsupported signature container, or a missing CodeDirectory fail the build.
    File bytes (including XML/DER entitlements/signatures) remain identical.
    """
    evidence = []
    for offset, part in macho_slices(raw):
        macho = MachO(part)
        signatures = [c for c in macho.commands if c["command"] == "0x1d"]
        require(len(signatures) == 1, "Expected one original embedded signature")
        start, size = struct.unpack_from("<II", part, int(signatures[0]["offset"], 16) + 8)
        blob = bytes(checked(part, start, size))
        magic, length, count = struct.unpack_from(">III", checked(blob, 0, 12))
        require(magic == 0xfade0cc0 and 12 <= length <= len(blob) and not any(blob[length:]) and 0 < count < 64,
                "Unsupported signature superblob")
        signature_hash = sha(blob)
        blob = blob[:length]
        checked(blob, 12, count * 8)
        directories = []
        for index in range(count):
            slot, child = struct.unpack_from(">II", blob, 12 + index * 8)
            child_magic, child_length = struct.unpack_from(">II", checked(blob, child, 8))
            entry = bytes(checked(blob, child, child_length))
            if child_magic != 0xfade0c02:
                continue
            checked(entry, 0, 44)
            hash_offset, _, special = struct.unpack_from(">III", entry, 16)
            hash_size, hash_type = struct.unpack_from(">BB", entry, 36)
            require(hash_size in (20, 32, 48) and special >= 3 and special <= 64,
                    "Unsupported CodeDirectory special slots")
            checked(entry, hash_offset - special * hash_size, special * hash_size)
            for number in (1, 3):
                value = bytes(checked(entry, hash_offset - number * hash_size, hash_size))
                require(value == bytes(hash_size), "Original Info/resources are signature-bound; refusing re-sign")
            directories.append({"slot": slot, "hash_type": hash_type, "info_and_resources_unbound": True})
        require(directories, "Missing original CodeDirectory")
        evidence.append({"slice_offset": offset, "cpu": macho.cpu, "subtype": macho.subtype,
                         "signature_sha256": signature_hash, "code_directories": directories})
    require(evidence, "Missing original Mach-O slices")
    return evidence


def validate_overlay(raw, filter_bytes):
    require(plistlib.loads(filter_bytes) == {"Filter": {"Bundles": ["com.socialbox.app"]}},
            "Overlay must target ONLY the preserved app bundle")
    slices = [(MachO(part), part) for _, part in macho_slices(raw)]
    require(len(slices) == 2 and {m.cpu for m, _ in slices} == {0x100000c}
            and {m.subtype & 0xffffff for m, _ in slices} == {0, 2}, "Overlay needs arm64 and arm64e slices")
    require(all(m.filetype == 6 for m, _ in slices), "Overlay must be a dylib")
    require(all(sum(c["command"] == "0x1d" for c in m.commands) == 1 for m, _ in slices),
            "Overlay must have an embedded signature in each slice")
    return [{"cpu": m.cpu, "subtype": m.subtype, "sha256": sha(part)} for m, part in slices]


def build_overlay(theos, ldid, sdk="26.5"):
    require((theos / "makefiles/common.mk").is_file(), "Theos not found")
    require(ldid.is_file() and os.access(ldid, os.X_OK), "Explicit Procursus ldid executable required")
    require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", sdk), "Explicit iOS SDK version required")
    before = production_input_snapshot()
    exact_units = " ".join(os.path.relpath(ROOT / name, ROOT / "lucid") for name in before["translation_units"])
    command = ["make", f"THEOS={theos.resolve()}", f"TARGET_CODESIGN={ldid.resolve()}",
               f"TARGET=iphone:clang:{sdk}:15.0",
               "LBXPresentation_FILES=" + exact_units,
               "TARGET_CODESIGN_FLAGS=-S", "THEOS_PACKAGE_SCHEME=rootless", "FINALPACKAGE=1", "ARCHS=arm64 arm64e"]
    subprocess.run(command + ["clean"], cwd=ROOT / "lucid", check=True)
    subprocess.run(command + ["stage"], cwd=ROOT / "lucid", check=True)
    # Theos's deb packager normally adds the scheme prefix AFTER stage. We use
    # only its staged files and our own audited packager adds /var/jb exactly once.
    stage = ROOT / "lucid/.theos/_/Library/MobileSubstrate/DynamicLibraries"
    dylib, filter_path = stage / "LBXPresentation.dylib", stage / "LBXPresentation.plist"
    require(dylib.is_file() and filter_path.is_file(), "Theos stage lacks the exact overlay/filter")
    raw = dylib.read_bytes()
    # Theos permits an OpenStep filter; canonicalize with Apple's plist parser,
    # then validate its complete structure before including it in the package.
    filters = subprocess.run(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(filter_path)],
                             check=True, capture_output=True).stdout
    validate_overlay(raw, filters)
    linked_output = validate_linked_overlay(dylib, raw)
    require_unchanged_inputs(before)
    return raw, filters, {**before, "captured_before_make": True, "unchanged_after_build": True,
                          "linked_output": linked_output,
                          "scope": "Exact source-owned translation units, quoted project headers, Makefile and filter; SDK/Theos inputs are outside this snapshot."}


def original_code_evidence(baseline, candidate):
    result = []
    for path, raw in sorted(baseline.items()):
        if raw[:4] not in MAGICS:
            continue
        require(candidate[path] == raw, "Original executable changed: " + path)
        result.append({"path": path, "sha256": sha(raw), "byte_identical_including_signature": True,
                       "slices": len(list(macho_slices(raw)))})
    require(result, "No preserved originals")
    return result


def make_payload(baseline, overlay, filters, icons):
    require(set(icons) == set(ICON_NAMES), "Only the two original SocialBox icon assets are accepted")
    require(not any(n.endswith("/_CodeSignature/CodeResources") for n in baseline),
            "Original resource envelope exists; refusing to invalidate it")
    require(not (set(baseline) & ADDED_PATHS), "Baseline already contains overlay paths")
    bindings = resource_bindings(baseline[BINARY])
    overlay_slices = validate_overlay(overlay, filters)
    info = plistlib.loads(baseline[INFO])
    require(info.get("CFBundleIdentifier") == "com.socialbox.app"
            and info.get("CFBundleExecutable") == "SocialBox"
            and info.get("CFBundleShortVersionString") == "3.1.0" and info.get("CFBundleVersion") == "1",
            "Original app ABI identity mismatch")
    info = display_metadata(info)
    info.update(CFBundleDisplayName="SocialBox", SocialBoxBuild=VERSION,
                CFBundleIconFile="SocialBoxIcon60", CFBundleIconFiles=["SocialBoxIcon60"],
                CFBundleIcons={"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["SocialBoxIcon60"], "UIPrerenderedIcon": False}})
    candidate = dict(baseline)
    candidate[INFO] = plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=True)
    for path, label in EXTENSION_COPY.items():
        if path not in baseline:
            continue
        original = plistlib.loads(baseline[path])
        executable = path.removesuffix("Info.plist") + original["CFBundleExecutable"]
        resource_bindings(baseline[executable])
        candidate[path] = plistlib.dumps(extension_metadata(original, label), fmt=plistlib.FMT_BINARY, sort_keys=True)
    candidate.update({OVERLAY: overlay, FILTER: filters})
    for name, size in zip(ICON_NAMES, (120, 180)):
        raw = icons[name]
        require(raw.startswith(b"\x89PNG\r\n\x1a\n") and raw[12:16] == b"IHDR"
                and struct.unpack_from(">II", raw, 16) == (size, size), "Unexpected SocialBox icon dimensions")
        candidate[APP + name] = raw
    validate_payload(baseline, candidate)
    return candidate, {"original_resource_binding": bindings, "overlay_slices": overlay_slices,
                       "original_programs": original_code_evidence(baseline, candidate)}


def validate_payload(baseline, candidate):
    require(set(candidate) - set(baseline) == ADDED_PATHS and set(baseline) <= set(candidate),
            "Candidate payload contains missing/unapproved paths")
    require({p for p in baseline if baseline[p] != candidate[p]} == presentation_paths(baseline),
            "Only reviewed app and extension display metadata may change")
    before, after = plistlib.loads(baseline[INFO]), plistlib.loads(candidate[INFO])
    require({k for k in before.keys() | after.keys() if before.get(k) != after.get(k)} <= INFO_KEYS,
            "Non-presentation Info.plist change")
    expected = display_metadata(before)
    require(all(after.get(key) == expected.get(key) for key in {*INFO_COPY, "CFBundleDocumentTypes", "UTExportedTypeDeclarations"}),
            "Unreviewed display copy or document routing change")
    for path, label in EXTENSION_COPY.items():
        if path in baseline:
            require(plistlib.loads(candidate[path]) == extension_metadata(plistlib.loads(baseline[path]), label),
                    "Unreviewed extension metadata or routing change")
    validate_overlay(candidate[OVERLAY], candidate[FILTER])
    original_code_evidence(baseline, candidate)


def shell_guard(baseline, controls, rollback_postinst, *, incoming_preinst=False,
                base_version=BASE_VERSION, installed_controls=None, baseline_modes=None,
                added_paths=None):
    """Read-only, exact-base guard shared by external preflight and preinst.

    No overridable prefix/PATH: a root-level maintainer script must not inspect a
    caller-selected tree and then act on the real bootstrap. Tests run in an
    explicitly rewritten isolated fixture, never through a production bypass.
    """
    # dpkg changes the old package status before invoking new-preinst. Only
    # the incoming script accepts that transitional state; the external
    # preflight requires a completely installed baseline. All original-byte,
    # version, ownership, control and collision checks still apply to both.
    admitted_states = "installed|half-installed|half-configured|unpacked" if incoming_preinst else "installed"
    require(re.fullmatch(r"[0-9][A-Za-z0-9.+~-]*", base_version), "Invalid pinned base version")
    if installed_controls is not None:
        require(set(installed_controls) == {"preinst", "postinst", "prerm"}, "Unreviewed prior control set")
        require(baseline_modes is not None and set(baseline_modes) == set(baseline), "Prior payload modes required")
    checks = []
    for path, raw in sorted(baseline.items()):
        checks.append(f"verify_parent_chain {shlex.quote('/' + path)}")
        checks.append(f"verify_file {shlex.quote('/' + path)} {sha(raw)}")
        if baseline_modes is not None:
            checks.append(f"[ \"$(stat -L -c %u:%g:%a {shlex.quote('/' + path)})\" = 0:0:{baseline_modes[path]:o} ] || fail 'Prior payload ownership/mode mismatch'")
    for path in sorted(ADDED_PATHS if added_paths is None else added_paths):
        checks.append(f"verify_parent_chain {shlex.quote('/' + path)}")
        checks.append(f"[ ! -e {shlex.quote('/' + path)} ] && [ ! -L {shlex.quote('/' + path)} ] || fail 'New overlay/icon destination already exists'")
    for name in (("preinst", "postinst", "prerm") if installed_controls is not None else ("postinst", "prerm")):
        checks.append(f"control_path=$($DQ --control-path {PACKAGE} {name}) || fail 'Missing installed {name}'")
        checks.append('verify_parent_chain "$control_path"')
        expected = installed_controls[name] if installed_controls is not None else (rollback_postinst if name == "postinst" else controls[name])
        checks.append(f"verify_file \"$control_path\" {sha(expected)}")
        checks.append('[ "$(stat -L -c %u "$control_path")" = 0 ] || fail \'Installed control is not root-owned\'')
        checks.append('[ -x "$control_path" ] && [ "$(stat -L -c %a "$control_path")" = 755 ] || fail \'Installed control must be executable mode 755\'')
    checks.extend([f"verify_parent_chain {BACKUP_PATH}", f"verify_file {BACKUP_PATH} {sha(controls['postinst'])}",
                   f"[ \"$(stat -L -c %u {BACKUP_PATH})\" = 0 ] && [ \"$(stat -L -c %a {BACKUP_PATH})\" = 600 ] || fail 'Original control backup must be root-owned mode 600'",
                   f"[ \"$(stat -L -c %a {BACKUP_DIRECTORY})\" = 700 ] || fail 'Original control backup directory must be private mode 700'"])
    return """set -eu
PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
fail() { echo "SocialBox upgrade refused: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'Root is required for complete read-only preflight'
[ "$1" = upgrade ] && [ "${2:-}" = 'PINNED_BASE_VERSION' ] || fail 'Upgrade of pinned PINNED_BASE_VERSION only; no fresh installation'
[ -d /var/jb ] || fail 'Rootless bootstrap missing'
[ "${THEOS_PACKAGE_INSTALL_PREFIX:-/var/jb}" = /var/jb ] || fail 'Unsupported installation prefix'
if command -v jbroot >/dev/null 2>&1; then fail 'Roothide is not supported'; fi
DQ=/var/jb/usr/bin/dpkg-query
DPKG=/var/jb/usr/bin/dpkg
[ -x "$DQ" ] && [ -x "$DPKG" ] || fail 'Rootless dpkg is missing'
[ "$($DPKG --print-architecture)" = iphoneos-arm64 ] || fail 'Rootful/unsupported architecture'
status=$($DQ -W -f='${db:Status-Status}' com.socialbox 2>/dev/null) || fail 'Original package missing'
# Incoming preinst and the before-dpkg preflight have different state boundaries.
case "$status" in ADMITTED_PACKAGE_STATES) ;; *) fail 'Original package state is unsupported';; esac
[ "$($DQ -W -f='${Version}' com.socialbox)" = PINNED_BASE_VERSION ] || fail 'Original installed version mismatch'
firmware=$($DQ -W -f='${Version}' firmware) || fail 'Cannot determine firmware'
$DPKG --compare-versions "$firmware" ge 16.0 || fail 'This handoff requires iOS 16 or newer'
# The source-owned overlay imports this framework via these exact rootless
# rpaths. Read metadata only: existence is not an ABI/injection/trust test.
shim_found=0
for shim in /var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate /var/jb/usr/lib/CydiaSubstrate.framework/CydiaSubstrate; do
    if [ -f "$shim" ] && [ -r "$shim" ] && [ "$(stat -L -c %u "$shim")" = 0 ]; then
        shim_found=1
        break
    fi
done
[ "$shim_found" = 1 ] || fail 'Linked CydiaSubstrate shim is missing or unreadable at the supported rootless paths'
other=$($DQ -W -f='${db:Status-Status}' com.redditbox 2>/dev/null || true)
case "$other" in ''|not-installed|config-files) ;; *) fail 'Separate com.redditbox exists; reviewed migration is required (nothing was removed)';; esac
other=$($DQ -W -f='${db:Status-Status}' com.socialbox.roothide 2>/dev/null || true)
case "$other" in ''|not-installed|config-files) ;; *) fail 'Roothide package exists';; esac
verify_file() {
    [ -f "$1" ] && [ ! -L "$1" ] || fail "Missing/symlink baseline file: $1"
    actual=$(sha256sum "$1") || fail "Cannot hash baseline file: $1"
    [ "${actual%% *}" = "$2" ] || fail "Installed baseline differs: $1"
}
verify_parent() {
    [ -d "$1" ] || fail "Missing parent directory: $1"
    if [ -L "$1" ] && [ "$1" != /var/jb ]; then
        # The rootless bootstrap symlink and this exact injection-engine mapping
        # are the only admitted aliases. No generic realpath equivalence.
        [ "$1" = /var/jb/Library/MobileSubstrate/DynamicLibraries ] || fail "Unreviewed parent symlink: $1"
        target=$(readlink "$1")
        case "$target" in /var/jb/usr/lib/TweakInject|../../usr/lib/TweakInject) ;; *) fail 'Unreviewed injection-directory alias';; esac
        for target_parent in /var/jb/usr /var/jb/usr/lib /var/jb/usr/lib/TweakInject; do
            [ -d "$target_parent" ] && [ ! -L "$target_parent" ] || fail 'Injection target parent is missing or aliased'
            [ "$(stat -L -c %u "$target_parent")" = 0 ] || fail 'Injection target is not root-owned'
            [ "$((0$(stat -L -c %a "$target_parent") & 0022))" = 0 ] || fail 'Injection target is writable by another user'
        done
    fi
    [ "$(stat -L -c %u "$1")" = 0 ] || fail "Parent is not root-owned: $1"
    [ "$((0$(stat -L -c %a "$1") & 0022))" = 0 ] || fail "Parent is writable by another user: $1"
}
verify_parent_chain() {
    parent=${1%/*}
    while [ "$parent" != /var/jb ]; do
        case "$parent" in /var/jb/*) ;; *) fail 'Path outside the reviewed bootstrap';; esac
        case "$parent" in */../*|*/./*|*//*|*/..|*/.) fail 'Noncanonical parent path';; esac
        verify_parent "$parent"
        parent=${parent%/*}
    done
    verify_parent /var/jb
}
# Original prerm removes this alias before incoming preinst can run: check it
# in the external preflight too, while a foreign path can still be preserved.
alias=/var/jb/usr/bin/socialbox
if [ -L "$alias" ]; then
    [ "$(readlink "$alias")" = /var/jb/usr/local/bin/SocialBoxCLI ] || fail 'Foreign CLI alias'
elif [ -e "$alias" ]; then
    fail 'Foreign CLI alias/file'
fi
# These controls were absent from the handoff, NOT proven absent on the device.
for name in ABSENT_CONTROLS; do
    if path=$($DQ --control-path com.socialbox "$name" 2>/dev/null); then
        [ ! -e "$path" ] || fail "Installed $name was not supplied for review"
    fi
done
""".replace("ADMITTED_PACKAGE_STATES", admitted_states).replace("PINNED_BASE_VERSION", base_version).replace(
        "ABSENT_CONTROLS", "postrm" if installed_controls is not None else "preinst postrm") + "\n".join(checks) + "\n"


def maintainer_scripts(baseline, controls):
    postinst = """#!/bin/sh
set -eu
PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
# dpkg invokes the OLD postinst on an aborted upgrade/removal. Recover only
# these owned services; the original broad cleanup/injection script is not run.
case "${1:-}" in configure|abort-upgrade|abort-remove|abort-deconfigure) ;; *) exit 0;; esac
# Only the original CLI alias; refuse a foreign file/link rather than replace it.
alias=/var/jb/usr/bin/socialbox
target=/var/jb/usr/local/bin/SocialBoxCLI
if [ -L "$alias" ]; then
    [ "$(readlink "$alias")" = "$target" ] || { echo 'Foreign socialbox alias; refusing replacement' >&2; exit 1; }
elif [ -e "$alias" ]; then
    echo 'Foreign socialbox alias; refusing replacement' >&2; exit 1
else
    ln -s "$target" "$alias"
fi
"""
    for service in SERVICES:
        postinst += f"""if launchctl print system/{service} >/dev/null 2>&1; then
    launchctl kickstart -k system/{service}
else
    launchctl bootstrap system /var/jb/Library/LaunchDaemons/{service}.plist
fi
"""
    postinst += """# Register only the preserved app path; never kill or reload system services.
uicache -p /var/jb/Applications/SocialBox.app
echo 'Owned service recovery/configuration complete; device acceptance remains NOT_RUN'
"""
    guard = shell_guard(baseline, controls, postinst.encode())
    incoming_guard = shell_guard(baseline, controls, postinst.encode(), incoming_preinst=True)
    preinst = "#!/bin/sh\n" + incoming_guard + "echo 'SocialBox exact-base preflight passed; device acceptance remains NOT_RUN'\n"
    prerm = """#!/bin/sh
set -eu
PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
case "${1:-}" in upgrade|remove|deconfigure) ;; *) exit 0;; esac
"""
    # Stop monitor first, so it cannot restart the two other owned services.
    for service in reversed(SERVICES):
        prerm += f"""if launchctl print system/{service} >/dev/null 2>&1; then
    launchctl bootout system/{service}
fi
"""
    prerm += """if [ "${1:-}" = remove ]; then
    uicache -u /var/jb/Applications/SocialBox.app
    alias=/var/jb/usr/bin/socialbox
    if [ -L "$alias" ] && [ "$(readlink "$alias")" = /var/jb/usr/local/bin/SocialBoxCLI ]; then
        rm -f "$alias"
    fi
fi
# User data, keychain, original apps, license and account state are preserved.
"""
    return {"preinst": preinst.encode(), "postinst": postinst.encode(), "prerm": prerm.encode()}, (
        "#!/bin/sh\n# READ ONLY: run before invoking dpkg, whose old prerm runs first.\n"
        "set -- upgrade 3.1.0-1\n" + guard + "echo 'PASS: exact reviewed base; runtime acceptance remains NOT_RUN'\n").encode()


def build_deb(payload, scripts, modes, dependencies):
    dependencies = re.sub(r"firmware \(>= [^)]*\),? ?", "", dependencies)
    control = (f"Package: {PACKAGE}\nVersion: {VERSION}\nArchitecture: iphoneos-arm64\n"
               "Name: SocialBox owner-base candidate (UNVALIDATED)\nMaintainer: SocialBox\n"
               "Section: Development\nPriority: optional\n"
               f"Depends: firmware (>= 16.0), {dependencies}\n"
               "Provides: com.youtweakin.socialbox\n"
               "X-SocialBox-Status: private-upgrade-only-unvalidated\n"
               "Description: Source-owned presentation and diagnostics over preserved owner binaries.\n"
               " Requires unchanged original 3.1.0-1, read-only preflight and device acceptance.\n"
               " Original licensing and network behavior remain; no isolation guarantee.\n").encode()
    controls = {"control": control, **scripts, "md5sums": "".join(
        f"{hashlib.md5(raw).hexdigest()}  {name}\n" for name, raw in sorted(payload.items())).encode()}
    members = {"debian-binary": b"2.0\n", "control.tar.gz": recovery.tar_bytes(controls, {n: 0o755 for n in scripts}),
               "data.tar.gz": recovery.tar_bytes(payload, modes)}
    output = bytearray(b"!<arch>\n")
    for name, raw in members.items():
        output += f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(raw):<10}`\n".encode()
        output += raw + (b"\n" if len(raw) % 2 else b"")
    return bytes(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("handoff", type=Path)
    parser.add_argument("--theos", type=Path, required=True)
    parser.add_argument("--ldid", type=Path, required=True)
    parser.add_argument("--sdk", default="26.5")
    parser.add_argument("--output", type=Path, required=True, help="New private directory; never overwritten")
    args = parser.parse_args()
    require(not args.output.exists(), "Output already exists")
    require(not args.output.resolve().is_relative_to(ROOT), "Recovered binaries belong in private storage outside the repository")
    manifest, files, baseline, modes, fields = load_handoff(args.handoff)
    overlay, filters, production_inputs = build_overlay(args.theos, args.ldid, args.sdk)
    icons = {name: (ROOT / "launcher/Resources" / name).read_bytes() for name in ICON_NAMES}
    payload, evidence = make_payload(baseline, overlay, filters, icons)
    original_controls = {n: files["package-control/" + n] for n in ("prerm", "postinst")}
    scripts, preflight = maintainer_scripts(baseline, original_controls)
    modes.update({OVERLAY: 0o755, FILTER: 0o644, **{APP + n: 0o644 for n in ICON_NAMES}})
    # Preserve the installed privilege modes explicitly set by original postinst;
    # no new program gets setuid/setgid. The imported postinst is never executed.
    for name in (BINARY, "var/jb/usr/local/bin/SocialBoxCLI"):
        modes[name] = 0o6775
    deb = build_deb(payload, scripts, modes, fields["Depends"])
    report = {"schema_version": 1, "package": PACKAGE, "version": VERSION, "base_version": BASE_VERSION,
              "status": "UNVALIDATED_UPGRADE_ONLY", "installed": False, "device_acceptance": "NOT_RUN",
              "handoff_sha256": recovery.HANDOFF_SHA256, "builder_sha256": sha(Path(__file__).read_bytes()),
              "original_manifest_files": len(manifest["files"]), "payload_files": len(payload),
              "changed_original_paths": sorted(presentation_paths(baseline)), "added_paths": sorted(ADDED_PATHS),
              "original_controls_executed": False, "original_programs_resigned": False,
              "package_sha256": sha(deb), "overlay_sha256": sha(overlay), "ldid_sha256": sha(args.ldid.read_bytes()),
              "production_build_inputs": production_inputs,
              "presentation_sources_scope": "Historical all-lucid source snapshot including tests and unlinked research; not a linkage manifest. See production_build_inputs for compiled source provenance.",
              "presentation_sources": {str(p.relative_to(ROOT)): sha(p.read_bytes())
                  for p in sorted((ROOT / "lucid").rglob("*"))
                  if p.is_file() and ".theos" not in p.parts and (p.suffix in (".m", ".h", ".plist") or p.name == "Makefile")},
              "shared_sources": {name: production_inputs["sha256"][name]
                  for name in ("shared/RBXHTTPProxy.h", "shared/RBXHTTPProxy.m")},
              "maintainer_scripts_sha256": {n: sha(raw) for n, raw in scripts.items()},
              "preserved_installed_setuid_paths": [BINARY, "var/jb/usr/local/bin/SocialBoxCLI"],
              "deployment_requirements": [
                  "DEPLOYMENT BLOCKED until emitted narrow rollback-postinst.sh is separately reviewed/applied as the old package postinst with the exact original backed up privately. No preparation was applied by this builder.",
                  "The original postinst has no action guard: direct dpkg can execute its broad system/data actions on abort-upgrade. Merely checking its original hash is insufficient.",
                  "Run emitted read-only preflight BEFORE dpkg; original prerm runs before incoming preinst.",
                  "Original preinst/postrm absent from handoff: any installed instance blocks pending review.",
                  "Existing com.redditbox is preserved and blocks installation pending an explicit tested migration.",
                  "Close original app and review active tunnel/account state before any upgrade; no automatic reset.",
                  "Acceptance must verify injection, signing trust, original services, licensing and rollback.",
                  "Preflight checks the linked CydiaSubstrate framework is present/readable/root-owned at an exact rootless rpath; runtime ABI, symbol resolution and actual injection remain NOT_RUN.",
                  "No MDM/per-app/kernel network enforcement or fail-closed guarantee added by this candidate."],
              **evidence}
    preparation = {"status": "NOT_APPLIED_DEPLOYMENT_BLOCKER", "automatic_control_edits": False,
                   "installed_postinst_locator": "dpkg-query --control-path com.socialbox postinst",
                   "original_postinst_sha256": sha(original_controls["postinst"]),
                   "replacement_file": "rollback-postinst.sh", "replacement_sha256": sha(scripts["postinst"]),
                   "backup_path": BACKUP_PATH, "backup_sha256": sha(original_controls["postinst"]),
                   "backup_owner_uid": 0, "backup_mode": "0600", "backup_directory_mode": "0700",
                   "replacement_owner_uid": 0, "replacement_mode": "0755",
                   "steps": [
                       "Do not invoke dpkg yet. Review this source-owned rollback script and the installed old controls with a tested recovery connection.",
                       "Read-only verify the installed old postinst matches original_postinst_sha256; any other control requires a new review.",
                       "Make the exact original backup at backup_path in a root-owned private directory; do not replace an existing different backup.",
                       "Separately and atomically install the reviewed rollback-postinst.sh as the old postinst, preserving a root-owned non-writable control path. This builder does not perform that write.",
                       "Run upgrade-preflight.sh before dpkg. Resolve every blocker, including existing com.redditbox, unexpected controls, aliases or new-file collisions.",
                       "Only after device-specific review, stop the active app/tunnel safely and perform the upgrade with a recovery/rollback plan. Test abort recovery without original cleanup."]}
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for name, raw, mode in (("socialbox-owner-base-unvalidated.deb", deb, 0o600),
                            ("upgrade-preflight.sh", preflight, 0o700),
                            ("rollback-postinst.sh", scripts["postinst"], 0o700),
                            ("deployment-preparation.json", (json.dumps(preparation, indent=2, sort_keys=True) + "\n").encode(), 0o600),
                            ("build-report.json", (json.dumps(report, indent=2, sort_keys=True) + "\n").encode(), 0o600)):
        path = args.output / name
        with path.open("xb") as stream:
            stream.write(raw)
        path.chmod(mode)
    print(json.dumps({"status": report["status"], "package_sha256": report["package_sha256"],
                      "preserved_programs": len(evidence["original_programs"]), "installed": False,
                      "output": str(args.output.resolve())}, indent=2))


if __name__ == "__main__":
    main()
