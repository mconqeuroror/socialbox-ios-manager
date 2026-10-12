#!/usr/bin/env python3
"""Build an offline, PRIVATE owner-UI composition; its deb refuses installation.

The accepted owner source supplies every implementation except the reviewed
Containers review/actions, blue presentation and explicit update handoff. This neither authorizes an owner update
nor supplies first-customer provisioning. No device or network is contacted.
"""
import argparse
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
BASE = "ca333e80d89e3ee86f3c62a77503738430239467"
BASE_TREE = "81ca825314080cc958a20e5abfd9e5080013650f"
PROGRESS = "a6011d5179930dfa18f0b3dec74a5f63007e87fb"
EXPRESSION = "$(wildcard Presentation/*.m) $(wildcard Diagnostics/*.m) $(wildcard ProxyInput/*.m) ../shared/RBXHTTPProxy.m Authorization/LBXLicenseClient.m Authorization/LBXLicenseIPC.m Authorization/LBXLicensePeer.m HelperSafety/LBXCallerFile.m"
CLIENTS = ("Authorization/LBXLicenseClient.m", "Authorization/LBXLicenseIPC.m", "Authorization/LBXLicensePeer.m", "HelperSafety/LBXCallerFile.m")
UPDATES = {"lucid/Presentation/SBSwitchProgress.h": PROGRESS}
SOURCE_PINS = {
    "lucid/Presentation/LBXPresentation.m": "bad95b816d3d033b1367d9452ddca4efece8cb6b4fab9dde77dab3b67edac4da",
    "lucid/Presentation/LBXDisplayCopy.m": "cebb3034df137b449f61b7c2e60f5b2bff682e006169feabb3834d273c202dcb",
    "lucid/Presentation/LBXDisplayCopy.h": "87ad44fc58d19f21ea35d9a234abb2c7f964ae2cd5c2201c034af585e64293ca",
    "lucid/Presentation/LBXWorkspace.m": "dca701ef48f7a8ad8bab26dc444bb9fa6e18606130a28542e1368dfb3ad45c19",
    "lucid/Presentation/SBContainersView.m": "74fdcbfe8f52b22bcbda2750c0ad0a530bca74db94abe21950cf433f1e7f5e10",
    "lucid/Presentation/SBInterfaceCopy.m": "733c2ab9e1d53ad0f43e9d8fb7e6ddc31711d153c28bdc25a5e2aa059c65ac37",
    "lucid/Presentation/SBSwitchProgress.m": "99e215899320afdad336d9704eb0fad5a545ac42b776ac2b1b8a1e4dd65522cd",
    "lucid/Presentation/SBDesign.m": "1c6d2d668a20b45c26c1ac3c31c171db955c1a3c54ebffbc40d3b3563649a37a",
    "lucid/Diagnostics/LBXIsolationViewController.m": "d09a74a66907c7e95ec2cbd3c1e942d80b8260f78a0270ebd85fa14f92189ea0",
    "lucid/Presentation/SBUpdateService.h": "5ab23153aeae287f4a3b52a49338e4f41c79126acc844e417f60f3852a26238d",
    "lucid/Presentation/SBUpdateService.m": "0b5e45ae395fed81b0ca9da47f5353f696ac9dc7cf4159500798933043746930",
}
CREATION_KEYS = ("reviewTitle", "reviewDetail", "model", "system", "deviceName", "settings", "settingsDetail", "continue", "cancel")
UPDATE_KEYS = ("openManager", "openFailed")
CONTAINER_KEYS = ("selectedName", "swipeHint")
OVERLAY = "var/jb/Library/MobileSubstrate/DynamicLibraries/LBXPresentation.dylib"
FILTER = OVERLAY.removesuffix(".dylib") + ".plist"
IDENTIFIER = "com.socialbox.presentation.owner-ui"
REQUIRED = ("LBXPresentationInstall", "LBXPresentationStatus", "LBXWorkspaceApply", "LBXWorkspaceRefresh",
            "LBXWorkspaceStatus", "LBXPlanProxyInput", "LBXDispatchProxyInput", "LBXDisplayCopy", "SBSwitchProgressInstall")
FORBIDDEN = (b"SBPresentSavedContainerSetups", b"LBXContainerRootMutationCoordinator", b"LBXSendContainerMutationRequest",
             b"testUseStepBudget:", b"testUseLicenseSender:mutationSender:", b"SBSwitchProgressFixtureReduceMotion",
             b"LBXPresentationFixtureMetadata", b"LBXPresentationApplyFixture", b"LBXInstallProxyInputFixture")
REFUSE = b'#!/bin/sh\nprintf "%s\\n" "Private composition only. Owner/device acceptance is required; installation is unavailable." >&2\nexit 78\n'
CONTROL = ("Package: com.socialbox.owner-ui-composition\nVersion: 0.0.0+review.1\nArchitecture: iphoneos-arm64\n"
           "Name: SocialBox owner UI composition (PRIVATE - NOT INSTALLABLE)\nSection: Development\n"
           "Maintainer: SocialBox private testing\nPriority: optional\n"
           "X-SocialBox-Installable: false\nX-SocialBox-Customer-Ready: false\n"
           "Description: Offline review of two UI files only. Preinst and postinst refuse every invocation.\n"
           " No original programs, licensing job, installer, credentials or state are included.\n").encode()
CONTRACTS = ("tools/build_socialbox_owner_ui.py", "tools/verify_socialbox_presentation.py",
             "tools/enumerate_leak_binary.py")
sys.dont_write_bytecode = True


def require(value, message):
    if not value:
        raise ValueError(message)


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


verification = module("owner_ui_journal", ROOT / "tools/verify_socialbox_presentation.py")
binary = module("owner_ui_macho", ROOT / "tools/enumerate_leak_binary.py")
read = verification.read_regular
digest = verification.digest


def contracts():
    return {name: digest(read(ROOT / name, 2 * 1024 * 1024)) for name in CONTRACTS}


def graph(files):
    make = files["lucid/Makefile"].decode()
    assignments = re.findall(r"(?m)^LBXPresentation_FILES\s*=\s*(.*)$", make)
    require(assignments == [EXPRESSION], "Unreviewed baseline source selection")
    groups = ("lucid/Presentation/", "lucid/Diagnostics/", "lucid/ProxyInput/")
    units = sorted(name for name in files if name.endswith(".m") and any(
        name.startswith(group) and "/" not in name[len(group):] for group in groups))
    units += ["shared/RBXHTTPProxy.m", *["lucid/" + name for name in CLIENTS]]
    units = sorted(units)
    pending, observed = list(units), {}
    while pending:
        name = pending.pop()
        if name in observed:
            continue
        require(name in files, "Missing project input: " + name)
        raw = files[name]
        observed[name] = digest(raw)
        for quoted in re.findall(r'^\s*#\s*(?:import|include)\s*"([^"\n]+)"', raw.decode(), re.M):
            candidates = [str(PurePosixPath(name).parent / quoted), *[group + quoted for group in groups]]
            # Normalize dots without filesystem resolution; all reads are fixed Git blobs.
            candidates = [os.path.normpath(candidate) for candidate in candidates]
            header = next((candidate for candidate in candidates if candidate in files), None)
            require(header is not None and header.endswith(".h") and not header.startswith("../"), "Missing/escaping header")
            pending.append(header)
    for name in ("lucid/Makefile", "lucid/LBXPresentation.plist"):
        observed[name] = digest(files[name])
    return {"translationUnits": units, "sha256": dict(sorted(observed.items()))}


def compose(journal):
    tree, _ = journal.run("baseline-tree", ["/usr/bin/git", "-C", str(ROOT), "rev-parse", BASE + "^{tree}"])
    require(tree.decode().strip() == BASE_TREE, "Accepted source tree pin differs")
    listing, _ = journal.run("baseline-files", ["/usr/bin/git", "-C", str(ROOT), "ls-tree", "-rz", BASE])
    entries = {}
    for row in listing.rstrip(b"\0").split(b"\0"):
        metadata, name = row.split(b"\t", 1)
        mode, kind, oid = metadata.decode().split(" ")
        name = name.decode()
        # Read production source/header candidates only, never fixture state or archives.
        keep = name in ("lucid/Makefile", "lucid/LBXPresentation.plist") or (
            name.endswith((".m", ".h")) and name.startswith(("lucid/Presentation/", "lucid/Diagnostics/",
                "lucid/ProxyInput/", "lucid/Authorization/", "lucid/HelperSafety/", "shared/")) and "/Tests/" not in name)
        if keep:
            require(mode in ("100644", "100755") and kind == "blob", "Nonregular source blob")
            entries[name] = oid
    # A fixed Git tree supplies bounded regular source blobs, including newlines.
    blobs, _ = journal.run("baseline-blobs", ["/usr/bin/git", "-C", str(ROOT), "archive", "--format=tar", BASE, *sorted(entries)])
    files = {}
    with tarfile.open(fileobj=io.BytesIO(blobs), mode="r:") as archive:
        for item in archive:
            if item.isdir():
                continue
            require(item.isfile() and item.name in entries and item.name not in files and item.size <= 2 * 1024 * 1024,
                    "Unexpected source archive member")
            files[item.name] = archive.extractfile(item).read()
    require(set(files) == set(entries), "Source archive omitted inputs")
    before = graph(files)
    # Discard all unlinked candidates. Only the exact dependency graph is composed.
    files = {name: files[name] for name in before["sha256"]}
    originals = dict(files)
    reviewed = {}
    for index, (name, expected) in enumerate(SOURCE_PINS.items()):
        raw = read(ROOT / name, 2 * 1024 * 1024)
        require(digest(raw) == expected, "Reviewed UI source differs from fixed byte pin")
        journal.write("reviewed-source-" + str(index) + ".txt", raw)
        reviewed[name] = raw
    for name, raw in reviewed.items():
        if name not in ("lucid/Presentation/SBInterfaceCopy.m", "lucid/Presentation/LBXWorkspace.m", "lucid/Presentation/LBXPresentation.m"):
            files[name] = raw
    for index, (name, commit) in enumerate(UPDATES.items()):
        raw, _ = journal.run("reviewed-edit-" + str(index), ["/usr/bin/git", "-C", str(ROOT), "show", commit + ":" + name])
        require(raw == read(ROOT / name, 2 * 1024 * 1024), "Reviewed UI source differs from working source")
        files[name] = raw
    copy_name = "lucid/Presentation/SBInterfaceCopy.m"
    copy = files[copy_name]
    replacements = [(b'@"containers.create":@"New container",', b'@"containers.create":@"Create container",'),
        (b'@"containers.empty":@"Create your first container to keep its data and assigned apps in one place.",',
         b'@"containers.empty":@"No containers yet.",\n            @"containers.tryAgain":@"Please try again.",')]
    for old, new in replacements:
        require(copy.count(old) == 1, "Baseline copy anchor differs")
        copy = copy.replace(old, new)
    # Import only the nine reviewed presentation strings. Later activation,
    # saved-settings and readiness copy/implementations remain excluded.
    require(b'@"creation.' not in copy, "Baseline already contains creation review copy")
    snippets = []
    for key in CREATION_KEYS:
        matches = re.findall(rb'^\s+@"creation\.' + key.encode() + rb'":@"[^"\n]*",\n', reviewed[copy_name], re.M)
        require(len(matches) == 1, "Missing/ambiguous creation review copy")
        snippets.append(matches[0].lstrip(b"\n"))
    anchor = b'            @"containers.tryAgain":@"Please try again.",\n'
    require(copy.count(anchor) == 1, "Creation review copy anchor differs")
    copy = copy.replace(anchor, anchor + b"".join(snippets))
    for key in UPDATE_KEYS:
        matches = re.findall(rb'^\s+@"updates\.' + key.encode() + rb'":@"[^"\n]*",\n', reviewed[copy_name], re.M)
        require(len(matches) == 1 and ('@"updates.' + key + '"').encode() not in copy,
                "Missing/ambiguous update handoff copy")
        copy = copy.replace(anchor, anchor + matches[0].lstrip(b"\n"))
    for key in CONTAINER_KEYS:
        matches = re.findall(rb'^\s+@"containers\.' + key.encode() + rb'":@"[^"\n]*",\n', reviewed[copy_name], re.M)
        require(len(matches) == 1 and ('@"containers.' + key + '"').encode() not in copy,
                "Missing/ambiguous container action copy")
        copy = copy.replace(anchor, anchor + matches[0].lstrip(b"\n"))
    files[copy_name] = copy
    workspace_name = "lucid/Presentation/LBXWorkspace.m"
    start = b"    // Begin reviewed update settings entry.\n"
    end = b"    // End reviewed update settings entry.\n"
    workspace = reviewed[workspace_name]
    require(workspace.count(start) == 1 and workspace.count(end) == 1, "Ambiguous update settings entry")
    entry = workspace[workspace.index(start):workspace.index(end) + len(end)]
    anchor = b'    [self.body addArrangedSubview:[self page:SBUIText(@"settings.license") subtitle:SBUIText(@"settings.licenseDetail") items:license]];\n'
    require(files[workspace_name].count(anchor) == 1 and start not in files[workspace_name], "Baseline settings anchor differs")
    files[workspace_name] = files[workspace_name].replace(anchor, anchor + entry)
    start = b"    // Begin reviewed proxy empty-state removal.\n"
    end = b"    // End reviewed proxy empty-state removal.\n"
    require(workspace.count(start) == 1 and workspace.count(end) == 1, "Ambiguous proxy empty-state removal")
    empty_removal = workspace[workspace.index(start):workspace.index(end) + len(end)]
    anchor = b"    if(current && (tree || !current.available) && [current.sources isEqual:labels] && [current.controls isEqual:controls] && [current.indicators isEqual:images]) {\n"
    require(files[workspace_name].count(anchor) == 1 and start not in files[workspace_name], "Baseline proxy empty-state anchor differs")
    files[workspace_name] = files[workspace_name].replace(anchor, empty_removal + anchor)
    start = b"// Begin reviewed native proxy context preservation.\n"
    end = b"// End reviewed native proxy context preservation.\n"
    require(workspace.count(start) == 1 and workspace.count(end) == 1, "Ambiguous native proxy context helper")
    context_helper = workspace[workspace.index(start):workspace.index(end) + len(end)]
    anchor = b"static NSString *ProxyRole(UIView *carrier, NSArray<UILabel *> *labels, NSArray<UIControl *> *controls, NSArray *images) {\n"
    require(files[workspace_name].count(anchor) == 1 and start not in files[workspace_name], "Baseline proxy context helper anchor differs")
    files[workspace_name] = files[workspace_name].replace(anchor, context_helper + anchor)
    start = b"    // Begin reviewed native proxy context admission.\n"
    end = b"    // End reviewed native proxy context admission.\n"
    require(workspace.count(start) == 1 and workspace.count(end) == 1, "Ambiguous native proxy context admission")
    context_admission = workspace[workspace.index(start):workspace.index(end) + len(end)]
    old_context = b"""    if(current && (tree || !current.available) && [current.sources isEqual:labels] && [current.controls isEqual:controls] && [current.indicators isEqual:images]) {
        for(LBXViewBinding *binding in current.bindings) binding.update();
        if(!current.available) for(UIView *view in ProxyContent(carrier).subviews) if(view!=current) view.hidden=YES;
        [ProxyContent(carrier) bringSubviewToFront:current];return;
    }
    NSString *role=tree?ProxyRole(carrier,labels,controls,images):nil;
"""
    require(files[workspace_name].count(old_context) == 1 and start not in files[workspace_name], "Baseline proxy context cache differs")
    files[workspace_name] = files[workspace_name].replace(old_context, context_admission)
    start = b"    // Begin reviewed native proxy visibility recovery.\n"
    end = b"    // End reviewed native proxy visibility recovery.\n"
    require(workspace.count(start) == 1 and workspace.count(end) == 1, "Ambiguous native proxy visibility recovery")
    visibility_recovery = workspace[workspace.index(start):workspace.index(end) + len(end)]
    old_visibility = b"""    for(UIView *view in content.subviews) {
        if([view isKindOfClass:UILabel.class]) {view.alpha=0;view.accessibilityElementsHidden=YES;}
        else view.hidden=YES;
    }
"""
    require(files[workspace_name].count(old_visibility) == 1 and start not in files[workspace_name], "Baseline proxy visibility differs")
    files[workspace_name] = files[workspace_name].replace(old_visibility, visibility_recovery)
    activation_name = "lucid/Presentation/SBActivationView.m"
    old_color = b"configuration.baseBackgroundColor=[UIColor colorWithRed:.2 green:.86 blue:.76 alpha:1]"
    new_color = b"configuration.baseBackgroundColor=[UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1]"
    require(files[activation_name].count(old_color) == 1, "Baseline activation color differs")
    files[activation_name] = files[activation_name].replace(old_color, new_color)
    hook_name = "lucid/Presentation/LBXPresentation.m"
    hook = files[hook_name]
    require(hook.count(b'#import "LBXPresentation.h"') == 1 and hook.count(b"    LBXInstalled = YES;\n") == 1, "Baseline hook anchor differs")
    hook = hook.replace(b'#import "LBXPresentation.h"', b'#import "LBXPresentation.h"\n#import "SBSwitchProgress.h"')
    hook = hook.replace(b"    LBXInstalled = YES;\n", b"    LBXInstalled = YES;\n    SBSwitchProgressInstall(); // Optional Containers artwork; original operation stays authoritative.\n")
    start = b"        // Begin reviewed native alert tint.\n"
    end = b"        // End reviewed native alert tint.\n"
    reviewed_hook = reviewed[hook_name]
    require(reviewed_hook.count(start) == 1 and reviewed_hook.count(end) == 1, "Ambiguous alert tint hook")
    tint_hook = reviewed_hook[reviewed_hook.index(start):reviewed_hook.index(end) + len(end)]
    old_start = b"        SEL present = @selector(presentViewController:animated:completion:);\n"
    old_end = b"            hook(cls, present, replacement, &original);\n        }\n"
    require(hook.count(old_start) == 1 and hook.count(old_end) == 1 and start not in hook,
            "Baseline alert presentation hook differs")
    hook = hook[:hook.index(old_start)] + tint_hook + hook[hook.index(old_end) + len(old_end):]
    files[hook_name] = hook
    after = graph(files)
    allowed = set(UPDATES) | set(SOURCE_PINS) | {hook_name, activation_name}
    changed = {name for name in set(files) | set(originals) if files.get(name) != originals.get(name)}
    require(changed == allowed, "Unexpected owner-source change")
    for name in originals:
        if name not in allowed:
            require(files[name] == originals[name], "Accepted implementation changed: " + name)
    require(not any("SBSavedContainer" in name or "Containers/" in name for name in after["sha256"]), "Later saved-settings implementation included")
    return files, {"acceptedCommit": BASE, "acceptedTree": BASE_TREE, "baselineGraph": before,
                   "composedGraph": after, "reviewedSourcePins": SOURCE_PINS, "changedFiles": sorted(changed), "preservedFiles": sorted(set(originals) - allowed),
                   "scope": "Exact Git source bytes and current reviewed edit bytes, not installed/mapped bytes or policy migration."}


def tar_bytes(files, modes):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, raw in sorted(files.items()):
            path = PurePosixPath(name)
            require(str(path) == name and not path.is_absolute() and ".." not in path.parts and "\\" not in name,
                    "Unsafe archive path")
            info = tarfile.TarInfo(name)
            info.uid = info.gid = info.mtime = 0
            info.mode, info.size = modes[name], len(raw)
            archive.addfile(info, io.BytesIO(raw))
    return gzip.compress(output.getvalue(), mtime=0)


def package(overlay, filters):
    payload = {OVERLAY: overlay, FILTER: filters}
    controls = {"control": CONTROL, "preinst": REFUSE, "postinst": REFUSE}
    members = {"debian-binary": b"2.0\n", "control.tar.gz": tar_bytes(controls, {"control": 0o644, "preinst": 0o755, "postinst": 0o755}),
               "data.tar.gz": tar_bytes(payload, {OVERLAY: 0o755, FILTER: 0o644})}
    result = bytearray(b"!<arch>\n")
    for name, raw in members.items():
        result += f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(raw):<10}`\n".encode()
        result += raw + (b"\n" if len(raw) % 2 else b"")
    return bytes(result)


def validate_package(raw, overlay, filters):
    require(raw.startswith(b"!<arch>\n") and len(raw) < 32 * 1024 * 1024, "Invalid package size/magic")
    position, members = 8, {}
    while position < len(raw):
        header = raw[position:position + 60]
        require(len(header) == 60 and header[-2:] == b"`\n", "Malformed ar header")
        name = header[:16].decode().strip().removesuffix("/")
        size = int(header[48:58])
        require(size >= 0 and name not in members and position + 60 + size <= len(raw), "Invalid ar member")
        expected_header = f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{size:<10}`\n".encode()
        require(header == expected_header, "Noncanonical ar metadata")
        members[name] = raw[position + 60:position + 60 + size]
        position += 60 + size
        if size % 2:
            require(raw[position:position + 1] == b"\n", "Invalid ar padding")
            position += 1
    require(position == len(raw) and set(members) == {"debian-binary", "control.tar.gz", "data.tar.gz"}
            and members["debian-binary"] == b"2.0\n", "Unexpected package members")
    inventories = []
    for key, expected, modes in [("control.tar.gz", {"control": CONTROL, "preinst": REFUSE, "postinst": REFUSE},
                                 {"control": 0o644, "preinst": 0o755, "postinst": 0o755}),
                                ("data.tar.gz", {OVERLAY: overlay, FILTER: filters}, {OVERLAY: 0o755, FILTER: 0o644})]:
        observed = {}
        with gzip.GzipFile(fileobj=io.BytesIO(members[key])) as stream:
            require(len(stream.read(32 * 1024 * 1024 + 1)) <= 32 * 1024 * 1024, "Oversized tar")
        with tarfile.open(fileobj=io.BytesIO(members[key]), mode="r:gz") as archive:
            for item in archive:
                require(item.isfile() and item.name in expected and item.name not in observed
                        and item.uid == item.gid == 0 and item.mode == modes[item.name] and item.size == len(expected[item.name]),
                        "Unexpected/unsafe package node")
                value = archive.extractfile(item).read()
                require(value == expected[item.name], "Altered package bytes/control")
                observed[item.name] = value
        require(set(observed) == set(expected), "Missing package files")
        inventories.append({name: {"sha256": digest(value), "bytes": len(value), "mode": oct(modes[name])}
                            for name, value in sorted(observed.items())})
    require(raw == package(overlay, filters), "Noncanonical package bytes")
    return {"control": inventories[0], "payload": inventories[1], "installable": False, "customerDeliveryReady": False}


def inspect_overlay(path, filters, ldid, journal):
    raw = read(path, 32 * 1024 * 1024)
    require(plistlib.loads(filters) == {"Filter": {"Bundles": ["com.socialbox.app"]}}, "Unexpected injection scope")
    slices = list(binary.macho_slices(raw))
    require(len(slices) == 2 and {binary.MachO(part).subtype & 0xffffff for _, part in slices} == {0, 2}, "Missing universal slices")
    rows = []
    for architecture in ("arm64", "arm64e"):
        part = next(part for _, part in slices if binary.MachO(part).subtype & 0xffffff == (0 if architecture == "arm64" else 2))
        macho = binary.MachO(part)
        require(macho.cpu == 0x100000c and macho.filetype == 6 and not any(marker in part for marker in FORBIDDEN), "Unexpected/forbidden overlay content")
        symbols_raw, _ = journal.run("exports-" + architecture, ["/usr/bin/xcrun", "nm", "-arch", architecture, "-gU", str(path)])
        symbols = verification.symbols(symbols_raw)
        require(all(symbols.get("_" + name) == "T" for name in REQUIRED) and not any(
            marker in name.lower() for name in symbols for marker in ("fixture", "testing", "lbxlicenseexchange")), "Missing/forbidden export")
        thin = journal.directory / (architecture + ".dylib")
        journal.run("thin-" + architecture, ["/usr/bin/lipo", str(path), "-thin", architecture, "-output", str(thin)])
        journal.run("signature-" + architecture, ["/usr/bin/codesign", "--verify", "--strict", "--verbose=4", str(thin)])
        _, details = journal.run("identity-" + architecture, ["/usr/bin/codesign", "-d", "--verbose=4", str(thin)])
        require(("Identifier=" + IDENTIFIER + "\n").encode() in details and b"Signature=adhoc" in details, "Unexpected signature identity")
        entitlements, _ = journal.run("entitlements-" + architecture, [str(ldid), "-e", str(thin)])
        require(entitlements in (b"", b"\n") or plistlib.loads(entitlements) == {}, "Unexpected entitlements")
        rows.append({"architecture": architecture, "sliceSHA256": digest(part), "exports": sorted(symbols), "strictAdHoc": True, "emptyEntitlements": True})
    require(read(path, 32 * 1024 * 1024) == raw, "Overlay changed during inspection")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--theos", type=Path, required=True)
    parser.add_argument("--ldid", type=Path, required=True)
    parser.add_argument("--sdk", default="26.5")
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", args.sdk), "Invalid SDK")
    require(args.theos.resolve() == args.theos and (args.theos / "makefiles/common.mk").is_file(), "Missing/aliased Theos")
    read(args.ldid, 32 * 1024 * 1024)
    require(os.access(args.ldid, os.X_OK), "Signer not executable")
    journal = verification.Journal(args.output)
    try:
        before = contracts()
        journal.document("contracts-before.json", before)
        files, provenance = compose(journal)
        source = journal.directory / "source"
        for name, raw in files.items():
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
        journal.document("provenance.json", provenance)
        units = " ".join(os.path.relpath(source / name, source / "lucid") for name in provenance["composedGraph"]["translationUnits"])
        command = ["/usr/bin/make", "-C", str(source / "lucid"), "THEOS=" + str(args.theos), "TARGET_CODESIGN=" + str(args.ldid),
                   "TARGET=iphone:clang:" + args.sdk + ":15.0", "LBXPresentation_FILES=" + units, "TARGET_CODESIGN_FLAGS=-S",
                   "THEOS_PACKAGE_SCHEME=rootless", "FINALPACKAGE=1", "ARCHS=arm64 arm64e", "stage"]
        # Theos supplies an initial signature. Bind our final universal bytes before inspection/hash/archive.
        verification.TOOL_TIMEOUT = 180
        journal.run("compile", command)
        stage = source / "lucid/.theos/_/Library/MobileSubstrate/DynamicLibraries"
        overlay = stage / "LBXPresentation.dylib"
        journal.run("sign-final", ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--identifier", IDENTIFIER,
                    "--requirements", '=designated => identifier "' + IDENTIFIER + '"', str(overlay)])
        filters, _ = journal.run("canonical-filter", ["/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(stage / "LBXPresentation.plist")])
        raw = read(overlay, 32 * 1024 * 1024)
        rows = inspect_overlay(overlay, filters, args.ldid, journal)
        journal.write("LBXPresentation.dylib", raw)
        journal.write("LBXPresentation.plist", filters)
        deb = package(raw, filters)
        inventory = validate_package(deb, raw, filters)
        journal.write("owner-ui-COMPOSITION-ONLY.deb", deb)
        observed = {name: read(source / name, 2 * 1024 * 1024) for name in files}
        require(graph(observed) == provenance["composedGraph"] and contracts() == before
                and all(read(ROOT / name, 2 * 1024 * 1024) == files[name] for name in UPDATES)
                and all(digest(read(ROOT / name, 2 * 1024 * 1024)) == expected for name, expected in SOURCE_PINS.items()), "Inputs changed during build")
        journal.document("build-report.json", {"status": "PASS", "sourceStable": True, "contracts": before, "provenance": provenance,
            "overlaySHA256": digest(raw), "overlayBytes": len(raw), "packageSHA256": digest(deb), "inventory": inventory,
            "slices": rows, "toolSteps": journal.rows, "deviceAction": False, "ownerInstallAccepted": False,
            "freshInstallReady": False, "customerDeliveryReady": False,
            "limits": "Host source composition/build/strict ad-hoc signatures only; no publisher/device trust, phone installation, runtime/isolation or license acceptance. SDK/Theos/OS/toolchain excluded from source freeze."})
        print(json.dumps({"status": "PASS", "overlaySHA256": digest(raw), "packageSHA256": digest(deb), "productionInputs": len(observed), "installable": False}))
    except BaseException as error:
        journal.document("failure.json", {"status": "FAIL", "error": type(error).__name__ + ": " + str(error), "deviceAction": False})
        raise
    finally:
        journal.close()


if __name__ == "__main__":
    main()
