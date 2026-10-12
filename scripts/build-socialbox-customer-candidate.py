#!/usr/bin/env python3
"""Compose a PRIVATE check-only first-install package candidate.

Unpack is separate from preparation. No emitted script creates source state:
configuration requires the fixed native EXISTING-ONLY check to succeed first.
An independently trusted first-preparation transaction is not supplied here.
No device is modified, imported controls executed, or customer release made.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("customer_helper_inputs", ROOT / "scripts/build-socialbox-helper-safety.py")
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
c = h.c
VERSION = "3.1.0-1+socialbox.customer.1"
SOURCE_STATE_PATHS = h.SOURCE_STATE_PATHS


def candidate_scope():
    return {
        "profile": "PRIVATE_FIRST_INSTALL_CHECK_ONLY_CANDIDATE",
        "freshInstallReady": False,
        "customerDeliveryReady": False,
        "initializerExecution": "NOT_RUN; no emitted lifecycle script invokes preparation",
        "externalFirstPreparationAuthority": "NOT_IMPLEMENTED; this profile neither issues nor infers authority",
        "configuration": "Exact installed files, then native existing-only prepared check, then licensing job and app registration",
        "repeatAndAbort": "Check-only; missing/partial/unknown state is preserved and startup refused",
        "imageMigration": "UNSUPPORTED; upgrade refuses before effects",
        "runtimeAcceptance": "NOT_RUN; saved metadata readiness is not retained runtime authority",
    }


def python_snapshot():
    # Freeze a conservative superset of repository Python imports, including
    # recovery/archive helpers. Native builders additionally freeze their own
    # complete quoted production dependency graphs.
    paths = set(ROOT.glob("scripts/*.py")) | set(ROOT.glob("tools/*.py"))
    for module in tuple(sys.modules.values()):
        filename = getattr(module, "__file__", None)
        if filename:
            path = Path(filename).absolute()
            if path.is_relative_to(ROOT) and path.suffix == ".py": paths.add(path)
    result = {}
    for path in sorted(paths):
        c.require(path.is_file() and not path.is_symlink() and path.resolve() == path,
                  "Missing or aliased Python input")
        result[str(path.relative_to(ROOT))] = c.sha(path.read_bytes())
    return result


HEADER = """#!/bin/sh
set -eu
PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
fail() { echo "SocialBox installation candidate refused: $*" >&2; exit 1; }
root_role() {
    [ "$(id -u)" = 0 ] && [ "$(id -ru)" = 0 ] || fail 'Real and effective root are required'
    [ "${THEOS_PACKAGE_INSTALL_PREFIX:-/var/jb}" = /var/jb ] || fail 'Unsupported installation prefix'
    [ -d /var/jb ] || fail 'Rootless bootstrap missing'
}
verify_parent() {
    [ -d "$1" ] || fail "Missing parent directory: $1"
    if [ -L "$1" ] && [ "$1" != /var/jb ]; then
        [ "$1" = /var/jb/Library/MobileSubstrate/DynamicLibraries ] || fail "Unreviewed parent alias: $1"
        case "$(readlink "$1")" in /var/jb/usr/lib/TweakInject|../../usr/lib/TweakInject) ;; *) fail 'Unreviewed injection alias';; esac
        for target_parent in /var/jb/usr /var/jb/usr/lib /var/jb/usr/lib/TweakInject; do
            [ -d "$target_parent" ] && [ ! -L "$target_parent" ] || fail 'Injection target is missing or aliased'
            [ "$(stat -L -c %u "$target_parent")" = 0 ] || fail 'Injection target is not root-owned'
            [ "$((0$(stat -L -c %a "$target_parent") & 0022))" = 0 ] || fail 'Injection target is writable'
        done
    fi
    [ "$(stat -L -c %u "$1")" = 0 ] || fail "Parent is not root-owned: $1"
    [ "$((0$(stat -L -c %a "$1") & 0022))" = 0 ] || fail "Parent is writable by another user: $1"
}
verify_parent_chain() {
    parent=${1%/*}
    while [ "$parent" != /var/jb ]; do
        case "$parent" in /var/jb/*) ;; *) fail 'Path escaped the fixed bootstrap';; esac
        verify_parent "$parent"
        parent=${parent%/*}
    done
    verify_parent /var/jb
}
verify_fresh_destination() {
    destination=$1
    [ ! -e "$destination" ] && [ ! -L "$destination" ] || fail "Destination already exists: $destination"
    parent=${destination%/*}
    while [ "$parent" != /var/jb ]; do
        case "$parent" in /var/jb/*) ;; *) fail 'Path escaped the fixed bootstrap';; esac
        if [ -e "$parent" ] || [ -L "$parent" ]; then verify_parent "$parent"; fi
        parent=${parent%/*}
    done
    verify_parent /var/jb
}
verify_installed_file() {
    verify_parent_chain "$1"
    [ -f "$1" ] && [ ! -L "$1" ] || fail "Missing or aliased installed file: $1"
    [ "$(stat -L -c %u "$1")" = 0 ] && [ "$(stat -L -c %g "$1")" = 0 ] || fail 'Installed file ownership differs'
    [ "$(stat -L -c %a "$1")" = "$3" ] && [ "$(stat -L -c %h "$1")" = 1 ] || fail 'Installed file mode or link count differs'
    actual=$(sha256sum "$1") || fail 'Cannot hash installed file'
    [ "${actual%% *}" = "$2" ] || fail "Installed bytes differ: $1"
}
"""


def unpack_guard(payload, incoming):
    incoming_rule = """[ "$seen_owner" = 0 ] || fail 'Duplicate manager inventory record'
            seen_owner=1
            [ "$architecture" = iphoneos-arm64 ] && [ "$version" = 'CUSTOMER_VERSION' ] && [ "$status" = half-installed ] || fail 'Existing manager state requires reviewed migration'""" if incoming else "fail 'Manager package is already recorded; reviewed migration is required'"
    guard = HEADER + """root_role
LC_ALL=C
export LC_ALL
[ "${1:-}" = install ] && [ "$#" = 1 ] || fail 'New-package unpack only; no upgrade or reinstall authority'
if command -v jbroot >/dev/null 2>&1; then fail 'Roothide is unsupported'; fi
DQ=/var/jb/usr/bin/dpkg-query
DPKG=/var/jb/usr/bin/dpkg
[ -x "$DQ" ] && [ -x "$DPKG" ] || fail 'Rootless dpkg is missing'
[ "$($DPKG --print-architecture)" = iphoneos-arm64 ] || fail 'Unsupported architecture'
firmware=$($DQ -W -f='${Version}' firmware) || fail 'Cannot determine firmware'
$DPKG --compare-versions "$firmware" ge 16.0 || fail 'iOS 16 or newer is required'
# A failed/partial catalog is never package absence. Read the complete successful
# result before examining any row. The incoming half-installed record permits
# this exact unpack transition only; it never authorizes source preparation.
catalog=$($DQ -W -f='${Package}\\t${Architecture}\\t${Version}\\t${db:Status-Status}\\n') || fail 'Cannot obtain complete package inventory'
seen_owner=0
tab=$(printf '\\t')
# Parse literal separators instead of whitespace IFS, which collapses empty
# columns. A successful empty catalog is only a zero-record observation;
# neither it nor any other catalog establishes pristine history or authority.
seen_records='|'
if [ -n "$catalog" ]; then
while IFS= read -r record; do
    [ -n "$record" ] || fail 'Blank row in package inventory'
    case "$record" in *"$tab"*) ;; *) fail 'Missing package inventory column';; esac
    package=${record%%"$tab"*}; record=${record#*"$tab"}
    case "$record" in *"$tab"*) ;; *) fail 'Missing package inventory column';; esac
    architecture=${record%%"$tab"*}; record=${record#*"$tab"}
    case "$record" in *"$tab"*) ;; *) fail 'Missing package inventory column';; esac
    version=${record%%"$tab"*}; status=${record#*"$tab"}
    case "$status" in *"$tab"*) fail 'Extra package inventory column';; esac
    [ -n "$package" ] && [ -n "$architecture" ] && [ -n "$version" ] && [ -n "$status" ] || fail 'Empty package inventory column'
    case "$architecture" in [!a-z0-9]*|*[!a-z0-9-]*) fail 'Malformed inventory architecture';; esac
    package_base=$package
    case "$package" in
        *:*) package_base=${package%%:*}; qualifier=${package#*:}
             [ "$qualifier" = "$architecture" ] || fail 'Ambiguous package architecture qualifier';;
    esac
    case "$package_base" in ''|[!a-z0-9]*|*[!a-z0-9+.-]*) fail 'Malformed inventory package name';; esac
    case "$version" in [0-9]*) ;; *) fail 'Malformed inventory version';; esac
    case "$version" in *[!a-zA-Z0-9.+:~\\-]*) fail 'Malformed inventory version';; esac
    case "$status" in not-installed|config-files|half-installed|unpacked|half-configured|triggers-awaited|triggers-pending|installed) ;;
        *) fail 'Unknown package inventory state';;
    esac
    record_key=$package_base:$architecture
    case "$seen_records" in *"|$record_key|"*) fail 'Duplicate package and architecture inventory record';; esac
    seen_records=$seen_records$record_key'|'
    case "$package_base" in
        com.socialbox|com.socialbox:*) INCOMING_RULE ;;
        com.redditbox|com.redditbox:*|com.socialbox.roothide|com.socialbox.roothide:*) fail 'Conflicting package history requires reviewed migration';;
    esac
done <<SOCIALBOX_FIXED_CATALOG
$catalog
SOCIALBOX_FIXED_CATALOG
fi
shim_found=0
for shim in /var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate /var/jb/usr/lib/CydiaSubstrate.framework/CydiaSubstrate; do
    if [ -f "$shim" ] && [ -r "$shim" ] && [ "$(stat -L -c %u "$shim")" = 0 ]; then shim_found=1; break; fi
done
[ "$shim_found" = 1 ] || fail 'Supported rootless substrate shim is unavailable'
""".replace("INCOMING_RULE", incoming_rule).replace("CUSTOMER_VERSION", VERSION)
    # Parent observations precede interpretation of absence. No mkdir/write or
    # native initializer occurs in either unpack guard.
    guard += "\n".join("verify_parent_chain " + shlex.quote(path) for path in SOURCE_STATE_PATHS) + "\n"
    guard += "\n".join("[ ! -e {0} ] && [ ! -L {0} ] || fail 'Source state exists; nothing was reset'".format(shlex.quote(path)) for path in SOURCE_STATE_PATHS) + "\n"
    guard += "\n".join("verify_fresh_destination " + shlex.quote("/" + path) for path in sorted(payload)) + "\n"
    guard += "echo 'PASS: unpack-only checks; trusted preparation and customer acceptance remain required'\n"
    return guard.encode()


def customer_scripts(payload, modes):
    c.require(bool(payload) and set(payload) == set(modes), "Exact payload modes are required")
    for name, raw in payload.items():
        c.require(isinstance(raw, bytes) and re.fullmatch(r"var/jb/[A-Za-z0-9_./@+\-]+", name)
                  and all(part not in ("", ".", "..") for part in name.split("/")), "Noncanonical payload path")
        c.require(type(modes[name]) is int and 0 <= modes[name] <= 0o7777 and not modes[name] & 0o22,
                  "Group/other-writable payload is unsupported")
        c.require(not any("/" + name == path or ("/" + name).startswith(path + "/") for path in SOURCE_STATE_PATHS),
                  "Source state must never be packaged")
    c.require({h.LICENSE_SERVICE, h.LICENSE_PLIST, h.LICENSE_INSTALLER, c.BINARY, c.INFO} <= set(payload),
              "Manager and licensing inputs are required")
    checks = "\n".join("verify_installed_file {0} {1} {2}".format(
        shlex.quote("/" + name), c.sha(raw), format(modes[name], "o")) for name, raw in sorted(payload.items()))
    postinst = HEADER + """case "${1:-}" in configure|abort-upgrade|abort-remove|abort-deconfigure) ;; *) exit 0;; esac
root_role
""" + checks + "\n" + """# Existing-only native provenance check. Failure preserves missing, consumed,
# partial and unknown state; there is deliberately no initializer fallback.
/var/jb/usr/libexec/socialbox-prepare-installation check >/dev/null || fail 'Trusted preparation is missing or recovery is required; no state was initialized'
if launchctl print system/com.socialbox.licensing >/dev/null 2>&1; then
    launchctl kickstart -k system/com.socialbox.licensing
else
    launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.socialbox.licensing.plist
fi
uicache -p /var/jb/Applications/SocialBox.app
"""
    prerm = HEADER + """case "${1:-}" in
    upgrade) fail 'Prepared image-policy migration is unsupported; no services or state were changed';;
    remove|deconfigure)
        root_role
        if launchctl print system/com.socialbox.licensing >/dev/null 2>&1; then launchctl bootout system/com.socialbox.licensing; fi
        ;;
    *) exit 0;;
esac
# No postrm, cleanup, credential/container removal or preparation command.
"""
    return {"preinst": unpack_guard(payload, True), "postinst": postinst.encode(), "prerm": prerm.encode()}, unpack_guard(payload, False)


def build_customer_deb(payload, scripts, modes, dependencies):
    expected, _ = customer_scripts(payload, modes)
    c.require(scripts == expected, "Only the generated check-only lifecycle controls are admitted")
    dependencies = re.sub(r"firmware \(>= [^)]*\),? ?", "", dependencies)
    c.require("\n" not in dependencies and "\r" not in dependencies, "Unexpected dependency syntax")
    control = (f"Package: {c.PACKAGE}\nVersion: {VERSION}\nArchitecture: iphoneos-arm64\n"
               "Name: SocialBox private installation candidate (UNVALIDATED)\nMaintainer: Sctweaks\n"
               "Section: Development\nPriority: optional\n"
               f"Depends: firmware (>= 16.0), {dependencies}\n"
               "X-SocialBox-Status: private-first-install-check-only-unvalidated\n"
               "Description: Preserved manager with source licensing and saved metadata.\n"
               " Requires an independently trusted external first-preparation transaction.\n"
               " No lifecycle initializer, image migration or runtime/account acceptance.\n").encode()
    controls = {"control": control, **scripts, "md5sums": "".join(
        f"{hashlib.md5(raw).hexdigest()}  {name}\n" for name, raw in sorted(payload.items())).encode()}
    members = {"debian-binary": b"2.0\n", "control.tar.gz": c.recovery.tar_bytes(controls, {name: 0o755 for name in scripts}),
               "data.tar.gz": c.recovery.tar_bytes(payload, modes)}
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
    parser.add_argument("--license-public-key", type=Path, required=True)
    parser.add_argument("--openssl", default="openssl")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    c.require(not args.output.exists() and not args.output.resolve().is_relative_to(ROOT), "Use a new private output outside the repository")
    before = python_snapshot()
    _, _, baseline, modes, fields = c.load_handoff(args.handoff)
    overlay, filters, overlay_inputs = c.build_overlay(args.theos, args.ldid, args.sdk)
    icons = {name: (ROOT / "launcher/Resources" / name).read_bytes() for name in c.ICON_NAMES}
    old_version = c.VERSION
    try:
        c.VERSION = VERSION
        payload, _ = c.make_payload(baseline, overlay, filters, icons)
    finally:
        c.VERSION = old_version
    args.output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix="socialbox-customer-owner-", dir=args.output.parent) as directory:
        owner_output = Path(directory) / "owner"
        subprocess.run([sys.executable, str(ROOT / "scripts/build-socialbox-license-service.py"), "--consumer", "manager",
                        "--public-key", str(args.license_public_key.resolve()), "--ldid", str(args.ldid.resolve()),
                        "--openssl", args.openssl, "--output", str(owner_output)], check=True)
        owner_report = json.loads((owner_output / "build-report.json").read_text())
        owner = (owner_output / "service").read_bytes()
        job = (owner_output / "service.plist").read_bytes()
        installer = (owner_output / "installer").read_bytes()
        c.require(owner_report["kind"] == "manager-license-owner-candidate" and owner_report["service"]["sha256"] == c.sha(owner)
                  and owner_report["launchdSHA256"] == c.sha(job) and owner_report["installer"]["sha256"] == c.sha(installer)
                  and owner_report["installerPath"] == "/" + h.LICENSE_INSTALLER, "Licensing build outputs differ")
        c.require(owner_report["client"]["sha256"] == c.sha(baseline[c.BINARY]) and owner_report["client"]["size"] == len(baseline[c.BINARY])
                  and owner_report["clientPath"] == "/" + c.BINARY, "Licensing client pin differs from packaged manager")
        payload = h.add_license_service(payload, owner, job, installer)
    c.require(set(payload) == set(baseline) | c.ADDED_PATHS | h.LICENSE_PATHS, "Unexpected customer payload paths")
    modes.update({c.OVERLAY: 0o755, c.FILTER: 0o644, **{c.APP + name: 0o644 for name in c.ICON_NAMES},
                  h.LICENSE_SERVICE: 0o755, h.LICENSE_INSTALLER: 0o755, h.LICENSE_PLIST: 0o644})
    modes[c.BINARY] = 0o6755
    modes["var/jb/usr/local/bin/SocialBoxCLI"] = 0o6755
    scripts, preflight = customer_scripts(payload, modes)
    deb = build_customer_deb(payload, scripts, modes, fields["Depends"])
    c.require(python_snapshot() == before, "Repository Python inputs changed during composition")
    report = {"schemaVersion": 1, "version": VERSION, **candidate_scope(), "installed": False,
              "package_sha256": c.sha(deb), "handoff_sha256": c.recovery.HANDOFF_SHA256,
              "python_build_inputs": before, "overlay_build_inputs": overlay_inputs, "license_owner_build": owner_report,
              "original_programs": c.original_code_evidence(baseline, payload), "original_programs_resigned": False,
              "controls_executed": False, "changed_original_modes": {c.BINARY: "06755", "var/jb/usr/local/bin/SocialBoxCLI": "06755"},
              "payload_sha256": {path: c.sha(raw) for path, raw in sorted(payload.items())},
              "payload_modes": {path: format(modes[path], "o") for path in sorted(payload)},
              "limitations": ["No independent preparation-authority issuer or customer first-install transaction.",
                              "Package guards are cooperative read-only observations, not a dpkg-wide lock.",
                              "Loaded licensing job ownership/lifetime and actual package lifecycle have not been accepted.",
                              "Retained runtime/account/proxy/switching/isolation and normal activation route remain unaccepted."]}
    args.output.mkdir(mode=0o700)
    for name, raw, mode in (("socialbox-customer-check-only-unvalidated.deb", deb, 0o600),
                            ("build-report.json", (json.dumps(report, indent=2) + "\n").encode(), 0o600),
                            ("unpack-preflight.sh", preflight, 0o700)):
        path = args.output / name
        path.write_bytes(raw)
        path.chmod(mode)
    print(json.dumps({"output": str(args.output.resolve()), "version": VERSION, "sha256": c.sha(deb), "installed": False}))


if __name__ == "__main__": main()
