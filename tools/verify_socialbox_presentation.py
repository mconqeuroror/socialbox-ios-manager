#!/usr/bin/env python3
"""Offline presentation artifact verification with retained, bounded tool journals.

Never loads the dylib, connects to a device, signs, installs or issues authority.
PASS binds explicitly pinned local bytes to the current quoted production graph;
it is not publisher/device trust or permission to replace owner state.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
CONTRACT_FILES = (
    "tools/verify_socialbox_presentation.py",
    "scripts/build-socialbox-recovered.py",
    "tools/recover_socialbox_base.py",
    "tools/enumerate_leak_binary.py",
    "tools/enumerate_facebook_binary.py",
)
MAX_ARTIFACT = 32 * 1024 * 1024
MAX_DOCUMENT = 2 * 1024 * 1024
MAX_TOOL_OUTPUT = 1024 * 1024
TOOL_TIMEOUT = 30


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def read_regular(path, bound):
    path = Path(os.path.abspath(path))
    require(path.resolve() == path, "Aliased input path")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and
                0 < before.st_size <= bound, "Expected bounded single-link regular input")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            raw = stream.read(bound + 1)
        after = os.fstat(descriptor)
        witness = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_nlink,
                             s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(len(raw) == before.st_size and witness(before) == witness(after) and
                witness(after) == witness(path.lstat()), "Input changed during observation")
        return raw
    finally:
        os.close(descriptor)


def snapshot_contract():
    return {name: digest(read_regular(ROOT / name, MAX_DOCUMENT)) for name in CONTRACT_FILES}


def load_contract():
    # Freeze repository-owned Python dependencies before this explicit import.
    # Standard library, macOS tools and SDK/Xcode configuration are excluded.
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(ROOT / "tools"))
    spec = importlib.util.spec_from_file_location("presentation_build_contract",
                                                ROOT / "scripts/build-socialbox-recovered.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Journal:
    def __init__(self, directory):
        self.directory = Path(os.path.abspath(directory))
        require(self.directory.parent.resolve() == self.directory.parent,
                "Aliased output parent")
        self.directory.mkdir(mode=0o700)  # Refuse every existing output node.
        self.fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.rows = []

    def close(self):
        os.close(self.fd)

    def write(self, name, raw):
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name), "Invalid journal filename")
        descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=self.fd)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.fsync(self.fd)

    def document(self, name, value):
        self.write(name, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())

    def run(self, name, command):
        require(not any(row["name"] == name for row in self.rows), "Duplicate tool step")
        output = {"stdout": bytearray(), "stderr": bytearray()}
        process = None
        status, returncode = "FAILED_TO_START", None
        started = time.monotonic()
        try:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"})
            status = "RUNNING"
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ, "stdout")
                selector.register(process.stderr, selectors.EVENT_READ, "stderr")
                while selector.get_map():
                    remaining = TOOL_TIMEOUT - (time.monotonic() - started)
                    if remaining <= 0:
                        status = "TIMEOUT"
                        raise ValueError("Tool timeout")
                    for key, _ in selector.select(min(remaining, 0.1)):
                        raw = os.read(key.fileobj.fileno(), 65536)
                        if not raw:
                            selector.unregister(key.fileobj)
                            continue
                        target = output[key.data]
                        available = MAX_TOOL_OUTPUT - len(target)
                        target.extend(raw[:available])
                        if len(raw) > available:
                            status = "OUTPUT_LIMIT"
                            raise ValueError("Tool output limit")
            remaining = TOOL_TIMEOUT - (time.monotonic() - started)
            if remaining <= 0:
                status = "TIMEOUT"
                raise ValueError("Tool timeout")
            returncode = process.wait(timeout=remaining)
            status = "PASS" if returncode == 0 else "EXIT_FAILURE"
            require(returncode == 0, "Tool returned failure")
        except subprocess.TimeoutExpired:
            status = "TIMEOUT"
            raise
        except BaseException:
            if status == "RUNNING":
                status = "PROCESS_ERROR"
            raise
        finally:
            if process is not None:
                # An exited leader can leave pipe-holding children in its group.
                # Failed/limited/timed-out steps stop that group as well.
                if process.poll() is None or status != "PASS":
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass  # Child/group already exited; retain the original outcome.
                process.wait()
                returncode = process.returncode
                process.stdout.close()
                process.stderr.close()
            row = {"name": name, "command": [str(part) for part in command],
                   "status": status, "returncode": returncode,
                   "stdoutSHA256": digest(output["stdout"]),
                   "stderrSHA256": digest(output["stderr"]),
                   "stdoutBytes": len(output["stdout"]), "stderrBytes": len(output["stderr"])}
            self.write(name + ".stdout", output["stdout"])
            self.write(name + ".stderr", output["stderr"])
            self.document(name + ".json", row)
            self.rows.append(row)
        return bytes(output["stdout"]), bytes(output["stderr"])


def symbols(raw):
    result = {}
    for line in raw.decode("utf-8").splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"\s*[0-9a-fA-F]+\s+([A-Za-z])\s+(\S+)\s*", line)
        require(match is not None and match[2] not in result, "Malformed or duplicate nm row")
        result[match[2]] = match[1]
    require(result, "Empty nm inventory")
    return result


def validate_symbols(values, contract):
    require(all(values.get("_" + name) == "T" for name in contract.REQUIRED_OVERLAY_EXPORTS),
            "Missing production export")
    require(values.get("_OBJC_CLASS_$_LBXContainerRootMutationCoordinator") in ("S", "D"),
            "Missing root coordinator class")
    require(not any(marker in name.lower() for name in values
                    for marker in ("fixture", "testing", "lbxlicenseexchange")),
            "Test or unlinked authorization export")


def json_object(raw):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, "Duplicate JSON key")
            value[key] = item
        return value
    result = json.loads(raw, object_pairs_hook=unique)
    require(isinstance(result, dict), "Expected build report object")
    return result


def verify(args, journal):
    # Reading a bare relative tool name and executing it through PATH would bind
    # different files. Use the same canonical absolute spelling in both steps.
    for name in ("overlay", "build_report", "ldid"):
        setattr(args, name, Path(os.path.abspath(getattr(args, name))))
    journal.document("invocation.json", {"overlay": str(args.overlay),
        "buildReport": str(args.build_report), "ldid": str(args.ldid),
        "expectedOverlaySHA256": args.expected_overlay_sha256,
        "expectedReportSHA256": args.expected_report_sha256,
        "deviceAction": False})
    before = snapshot_contract()
    journal.document("contract-before.json", before)
    contract = load_contract()
    raw = read_regular(args.overlay, MAX_ARTIFACT)
    report_raw = read_regular(args.build_report, MAX_DOCUMENT)
    ldid_raw = read_regular(args.ldid, MAX_ARTIFACT)
    require(args.ldid.stat().st_mode & 0o111, "Entitlement tool is not executable")
    require(digest(raw) == args.expected_overlay_sha256 and
            digest(report_raw) == args.expected_report_sha256, "Explicit input pin mismatch")
    report = json_object(report_raw)
    require(report.get("status") == "PASS" and report.get("sourceStable") is True and
            report.get("overlaySHA256") == digest(raw) and
            report.get("builderSHA256") == before["scripts/build-socialbox-recovered.py"],
            "Build report binding mismatch")
    current = contract.production_input_snapshot()
    require(report.get("productionInputs") == current, "Build graph differs from current source")
    journal.document("inputs-before.json", {"contract": before, "production": current})
    journal.write("overlay.dylib", raw)
    journal.write("build-report.json", report_raw)
    overlay = journal.directory / "overlay.dylib"
    filter_source = read_regular(ROOT / "lucid/LBXPresentation.plist", MAX_DOCUMENT)
    journal.write("filter-source.plist", filter_source)
    filters, _ = journal.run("filter-conversion", ["/usr/bin/plutil", "-convert", "xml1", "-o", "-",
                                                   str(journal.directory / "filter-source.plist")])
    contract.validate_overlay(raw, filters)
    journal.write("overlay.plist", filters)
    slices = {}
    for _, part in contract.macho_slices(raw):
        macho = contract.MachO(part)
        arch = {0: "arm64", 2: "arm64e"}.get(macho.subtype & 0xffffff)
        require(macho.cpu == 0x100000c and arch and arch not in slices,
                "Unsupported or duplicate Mach-O architecture")
        require(contract.PROXY_HOOK_MARKER in part and not any(
            name.encode() in part for name in contract.FORBIDDEN_OVERLAY_SEAMS),
            "Missing marker or testing seam in slice")
        slices[arch] = part
    require(set(slices) == {"arm64", "arm64e"}, "Need exactly both production architectures")
    journal.run("fat-strict", ["/usr/bin/codesign", "--verify", "--strict",
                              "--all-architectures", str(overlay)])
    linked = []
    for arch in ("arm64", "arm64e"):
        thin_name = "slice-" + arch + ".dylib"
        journal.write(thin_name, slices[arch])
        thin = journal.directory / thin_name
        journal.run(arch + "-strict", ["/usr/bin/codesign", "--verify", "--strict", str(thin)])
        _, details = journal.run(arch + "-details", ["/usr/bin/codesign", "--display",
                                                    "--verbose=4", str(thin)])
        require(details.decode("utf-8").splitlines().count("Signature=adhoc") == 1,
                "Expected explicitly observed ad-hoc signature")
        entitlements, _ = journal.run(arch + "-entitlements", [str(args.ldid), "-e", str(thin)])
        require(not entitlements.strip(), "Unexpected entitlement output")
        exports, _ = journal.run(arch + "-exports", ["/usr/bin/xcrun", "nm", "-arch", arch,
                                                    "-gU", str(overlay)])
        values = symbols(exports)
        validate_symbols(values, contract)
        linked.append({"architecture": arch, "sliceSHA256": digest(slices[arch]),
                       "exportedSymbols": dict(sorted(values.items()))})
    # Reobserve originals, copied outputs, source graph and verifier dependencies.
    require(read_regular(args.overlay, MAX_ARTIFACT) == raw and
            read_regular(args.build_report, MAX_DOCUMENT) == report_raw and
            read_regular(args.ldid, MAX_ARTIFACT) == ldid_raw, "Verification input drift")
    require(read_regular(overlay, MAX_ARTIFACT) == raw and
            read_regular(journal.directory / "build-report.json", MAX_DOCUMENT) == report_raw and
            read_regular(journal.directory / "filter-source.plist", MAX_DOCUMENT) == filter_source and
            read_regular(journal.directory / "overlay.plist", MAX_DOCUMENT) == filters and
            all(read_regular(journal.directory / ("slice-" + arch + ".dylib"), MAX_ARTIFACT) == part
                for arch, part in slices.items()), "Verification copy drift")
    after, production_after = snapshot_contract(), contract.production_input_snapshot()
    journal.document("inputs-after.json", {"contract": after, "production": production_after})
    require(before == after and current == production_after, "Verifier or production source drift")
    return {"schemaVersion": 1, "status": "PASS_OFFLINE_ARTIFACT_ONLY",
            "overlaySHA256": digest(raw), "buildReportSHA256": digest(report_raw),
            "filterSourceSHA256": digest(filter_source), "filterConvertedSHA256": digest(filters),
            "ldidSHA256": digest(ldid_raw), "contract": before, "production": current,
            "slices": linked, "toolSteps": journal.rows,
            "deviceInspected": False, "ownerInstallation": "NOT_RUN",
            "publisherDeviceTrust": "NOT_RUN", "customerDeliveryReady": False,
            "limits": "Instantaneous cooperating local observations and macOS ad-hoc integrity only. "
                      "No loaded-byte, device, backup, installation, first-provisioning, runtime or "
                      "rollback authority. macOS/SDK/toolchain/environment are outside the source snapshot."}


def sha_argument(value):
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise argparse.ArgumentTypeError("Expected lowercase SHA256")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("overlay", "build-report", "ldid", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("expected-overlay-sha256", "expected-report-sha256"):
        parser.add_argument("--" + name, type=sha_argument, required=True)
    args = parser.parse_args()
    journal = None
    try:
        journal = Journal(args.output)
        result = verify(args, journal)
        journal.document("result.json", result)
        print(json.dumps({"status": result["status"], "ownerInstallation": "NOT_RUN"}))
        return 0
    except (ValueError, OSError, UnicodeError, subprocess.SubprocessError) as error:
        if journal is not None:
            journal.document("failure.json", {"status": "FAIL_RETAINED", "errorType": type(error).__name__,
                                               "error": str(error), "toolSteps": journal.rows,
                                               "ownerInstallation": "NOT_RUN"})
        print("Offline artifact verification refused; retained private evidence, no device action.", file=sys.stderr)
        return 1
    finally:
        if journal is not None:
            journal.close()


if __name__ == "__main__":
    raise SystemExit(main())
