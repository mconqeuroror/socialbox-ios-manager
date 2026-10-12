#!/usr/bin/env python3
"""Recover an unmodified binary baseline from the owner's pinned handoff.

This is NOT a source build, a license patch, an installer, or a SocialBox release.
Imported scripts are stored, never executed. Outputs belong in private storage.
Only the exact reviewed handoff is accepted by the CLI; no network is used.
"""
import argparse
from collections import Counter
import csv
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import tarfile
import zipfile

from enumerate_leak_binary import MAGICS, MachO, macho_slices, sha
from enumerate_facebook_binary import signature_declarations

PREFIX = "socialbox-3.1.0-1/"
HANDOFF_SHA256 = "0c86afa9c87fbfe756ade7da75471111ab16f52f5100c6f97721789d5dc6d66f"
IPA_SHA256 = "91f011992565e9f38a41a74abafc0864e664608ee0d9a2e0e47aefb47f77adeb"
COUNTS = ("selector_references", "class_references", "class_definitions", "undefined_symbols",
          "method_name_strings", "swift_type_descriptors")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_members(z):
    members = z.infolist()
    require(len(members) <= 1000 and sum(i.file_size for i in members) <= 1024 ** 3,
            "Archive exceeds bounded handoff limits")
    names = set()
    for i in members:
        n = i.filename.rstrip("/")
        p = PurePosixPath(n)
        require(n and not p.is_absolute() and ".." not in p.parts and str(p) == n
                and "\\" not in n and "\x00" not in n and n not in names, "Unsafe/duplicate archive path")
        require(stat.S_IFMT(i.external_attr >> 16) in (0, stat.S_IFREG, stat.S_IFDIR),
                "Archive contains special file")
        require(i.file_size <= 256 * 1024 ** 2, "Oversized archive member")
        names.add(n)
    require(z.testzip() is None, "Archive CRC mismatch")
    return members


def verify_layout(z):
    members = safe_members(z)
    require(all(i.filename.startswith(PREFIX) for i in members), "Unexpected archive root")
    manifest = json.loads(z.read(PREFIX + "manifest.json"))
    require(manifest.get("package") == "com.socialbox" and manifest.get("version") == "3.1.0-1",
            "Unexpected package identity")
    files = {}
    for f in manifest["files"]:
        name = f["path"]
        require(name not in files and (name.startswith("compiled/var/jb/") or name in {
            "package-control/md5sums", "package-control/postinst", "package-control/prerm"}),
            "Unexpected/duplicate manifest member")
        raw = z.read(PREFIX + name)
        require(len(raw) == f["size"] and sha(raw) == f["sha256"], "Manifest payload mismatch: " + name)
        files[name] = raw
    actual = {i.filename[len(PREFIX):] for i in members if not i.is_dir()
              and i.filename.startswith(PREFIX + "compiled/")}
    require(actual == {n for n in files if n.startswith("compiled/")}, "Unlisted/missing compiled file")
    return manifest, files


def compare_ipa(z, files):
    members = safe_members(z)
    source = {n.removeprefix("compiled/var/jb/Applications/"): b for n, b in files.items()
              if n.startswith("compiled/var/jb/Applications/")}
    actual = {}
    for i in members:
        if i.is_dir():
            continue
        require(i.filename.startswith("Payload/"), "Unexpected IPA member")
        actual[i.filename.removeprefix("Payload/")] = z.read(i)
    require(source == actual, "IPA has missing/different app files")
    return {"files": len(actual), "all_byte_identical": True, "new_components": 0}


def tar_bytes(files, modes):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as t:
        directories = sorted({str(p) for n in files for p in PurePosixPath(n).parents if str(p) != "."})
        for name in directories:
            info = tarfile.TarInfo(name)
            info.type, info.mode = tarfile.DIRTYPE, 0o755
            t.addfile(info)
        for name, raw in sorted(files.items()):
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(raw), modes.get(name, 0o644)
            t.addfile(info, io.BytesIO(raw))
    return gzip.compress(buffer.getvalue(), mtime=0)


def recovery_deb(payload, scripts, modes, dependencies):
    # The legacy iOS 15 FileProvider is absent. Do not advertise this recovery
    # candidate for iOS 15 or infer rootful/roothide compatibility.
    dependencies = re.sub(r"firmware \(>= [^)]*\),? ?", "", dependencies)
    control = (
        "Package: com.socialbox\nVersion: 3.1.0-1+recovery.1\n"
        "Architecture: iphoneos-arm64\nName: SocialBox binary recovery (UNVALIDATED)\n"
        "Maintainer: SocialBox Recovery\nSection: Development\nPriority: optional\n"
        f"Depends: firmware (>= 16.0), {dependencies}\n"
        "Conflicts: com.youtweakin.socialbox, com.socialbox.roothide\n"
        "Replaces: com.youtweakin.socialbox\nProvides: com.youtweakin.socialbox\n"
        "X-SocialBox-Recovery-Status: unvalidated-binary-baseline\n"
        "Description: Recovered unchanged binaries; NOT the completed SocialBox integration.\n"
        " Original licensing and server dependencies remain. Device acceptance not run.\n"
    ).encode()
    md5sums = "".join(f"{hashlib.md5(b).hexdigest()}  {n}\n" for n, b in sorted(payload.items())).encode()
    controls = {"control": control, "md5sums": md5sums, **scripts}
    members = {"debian-binary": b"2.0\n",
               "control.tar.gz": tar_bytes(controls, {n: 0o755 for n in scripts}),
               "data.tar.gz": tar_bytes(payload, modes)}
    result = bytearray(b"!<arch>\n")
    for name, raw in members.items():
        result += f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(raw):<10}`\n".encode()
        result += raw + (b"\n" if len(raw) % 2 else b"")
    return bytes(result)


def inventory(z, files):
    details, components, totals = [], [], Counter()
    coverage = json.loads(z.read(PREFIX + "coverage.json"))
    coverage = {c["component"]: c for c in coverage["components"]}
    for path, raw in sorted(files.items()):
        if raw[:4] not in MAGICS:
            continue
        name = PurePosixPath(path).name
        entries = list(csv.DictReader(io.StringIO(z.read(PREFIX + f"decompiled/{name}.functions.tsv").decode()), delimiter="\t"))
        statuses = dict(Counter(e["status"] for e in entries))
        require(statuses == coverage[name]["functions"], "Function index / coverage mismatch: " + name)
        require(len({e['address'] for e in entries}) == len(entries), "Duplicate function address")
        text = z.read(PREFIX + f"decompiled/{name}.c").decode()
        # Recovery can rename an ObjC stub after the first export. Addresses,
        # not recovered function labels, bind blocks to the function index.
        headers = re.findall(r"^/\* (?:Recovered after extended analysis: )?([0-9a-f]+) \| .*? \*/$", text, re.M)
        expected = {e['address'] for e in entries if e['status'] in ('decompiled', 'decompiled_after_retry')}
        require(len(headers) == len(expected) and set(headers) == expected, "Pseudocode / index mismatch: " + name)
        component = {"name": name, "path": path, "sha256": sha(raw), "size": len(raw),
                     "functions": statuses, "slices": []}
        private = {"name": name, "functions": entries, "slices": []}
        for offset, part in macho_slices(raw):
            macho = MachO(part)
            full = macho.inventory()
            require(not any(full["unresolved_references"].values()), "Unresolved binary references: " + name)
            selected = {k: full[k] for k in ("sha256", "cpu_type", "cpu_subtype", "size", "file_type", "encryption", "dylibs")}
            selected["file_offset"] = hex(offset)
            selected["counts"] = {k: len(full[k]) for k in COUNTS}
            selected["api_family_counts"] = {k: len(v) for k, v in full['api_families'].items()}
            selected["signature_declarations"] = signature_declarations(part, macho)
            totals.update(selected["counts"])
            component["slices"].append(selected)
            private["slices"].append({"file_offset": hex(offset), **full})
        components.append(component)
        details.append(private)
    return components, details, dict(totals)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("handoff", type=Path)
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--output", type=Path, required=True, help="New private directory; will not overwrite")
    args = parser.parse_args()
    require(args.handoff.stat().st_size <= 256 * 1024 ** 2, "Handoff too large")
    raw = args.handoff.read_bytes()
    require(sha(raw) == HANDOFF_SHA256, "Handoff hash differs from reviewed input")
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        manifest, files = verify_layout(z)
        comparison = None
        if args.ipa:
            require(args.ipa.stat().st_size <= 64 * 1024 ** 2, "IPA too large")
            ipa_bytes = args.ipa.read_bytes()
            require(sha(ipa_bytes) == IPA_SHA256, "IPA hash differs from reviewed input")
            with zipfile.ZipFile(io.BytesIO(ipa_bytes)) as ipa:
                comparison = {"sha256": sha(ipa_bytes), **compare_ipa(ipa, files)}
        components, private, counts = inventory(z, files)
        payload = {n.removeprefix("compiled/"): b for n, b in files.items() if n.startswith("compiled/")}
        modes = {n: (z.getinfo(PREFIX + 'compiled/' + n).external_attr >> 16) & 0o777 for n in payload}
        require(all(modes.values()), "Missing payload permissions")
        scripts = {n: files['package-control/' + n] for n in ('postinst', 'prerm')}
        package_fields = dict(line.split('=', 1) for line in z.read(PREFIX + 'metadata/package-control.txt').decode().splitlines() if '=' in line)
        deb = recovery_deb(payload, scripts, modes, package_fields['Depends'])
        plists = {p: plistlib.loads(b) for p, b in files.items() if p.endswith('.plist')}
        detail = gzip.compress((json.dumps(private, sort_keys=True, separators=(',', ':')) + '\n').encode(), mtime=0)
        report = {
            "schema_version": 1, "handoff_sha256": sha(raw), "handoff_crc": "PASS",
            "manifest_file_count": len(files), "payload_file_count": len(payload), "ipa_comparison": comparison,
            "component_count": len(components), "slice_count": sum(len(c['slices']) for c in components),
            "structure_counts_across_all_slices": counts, "components": components, "bundle_and_filter_declarations": plists,
            "manifest": manifest, "private_inventory_sha256": sha(detail),
            "tool_sha256": sha(Path(__file__).read_bytes()),
            "scanner_sha256": sha(Path(__file__).with_name('enumerate_leak_binary.py').read_bytes()),
            "signature_parser_sha256": sha(Path(__file__).with_name('enumerate_facebook_binary.py').read_bytes()),
            "recovery_package": {"file": "socialbox-original-binary-recovery-unvalidated.deb", "sha256": sha(deb),
                                 "size": len(deb), "rebuilt_from_source": False, "executables_modified": False,
                                 "scripts_executed": False, "installed": False, "license_removed": False,
                                 "missing_original_controls": ["preinst", "postrm", "triggers", "conffiles"],
                                 "controls_note": "These are absent from handoff, not proven absent from the original release; postinst references a preinst.",
                                 "generated_control_changes": ["recovery version/name/description", "iOS >=16 because legacy FileProvider is missing", "recomputed md5sums for available payload"]},
            "limits": ["Recovered pseudocode is not buildable source.",
                       "All slices structurally scanned; handoff pseudocode covers only arm64.",
                       "References and entitlements are static declarations, not observed calls, effective permission or isolation evidence.",
                       "Binary-recovery package preserves original postinst/prerm, which contain privileged system changes; it has not been approved by device acceptance.",
                       "No runtime config, personal data, original build project, or server implementation supplied.",
                       "No hooks, licensing, cloud endpoints, brand resources or live device state changed."]}
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for name, data in {"inventory.json": (json.dumps(report, indent=2, sort_keys=True) + '\n').encode(),
                       "private-structural-inventory.json.gz": detail,
                       "socialbox-original-binary-recovery-unvalidated.deb": deb}.items():
        target = args.output / name
        with target.open('xb') as f:
            f.write(data)
        target.chmod(0o600)
    print(json.dumps({k: report[k] for k in ('handoff_crc', 'manifest_file_count', 'payload_file_count', 'component_count', 'slice_count', 'ipa_comparison', 'recovery_package')}, indent=2))


if __name__ == '__main__':
    main()
