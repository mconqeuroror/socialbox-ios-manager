#!/usr/bin/env python3
"""Guard source-owned UI copy; optionally inventory private inputs without executing them.

The binary inventory reports offsets and hashes, not raw diagnostics, URLs or keys.
Absence of unapproved source words is not evidence of on-device UI coverage.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
UI = Path("lucid/Presentation")
CATALOG = UI / "SBLegacyDisplayCatalog.m"
LEGACY = re.compile(r"doritos|secretsauce", re.IGNORECASE)
INPUT = re.compile(r'SB_LEGACY\(\s*@("(?:\\.|[^"\\])*")\s*\)')
# Consume C strings too, so the closing quote after a C "%@" is never
# mistaken for the opening quote of an Objective-C string.
OBJC_STRING = re.compile(r'(@?)("(?:\\.|[^"\\])*")')
# Every exemption is an exact literal in an exact file, with a runtime reason.
# Display prose belongs in marked compatibility inputs instead.
ABI_LITERALS = {}


def digest(value):
    return hashlib.sha256(value).hexdigest()


def catalog_inputs(root=ROOT):
    # Only whole fixed-copy keys count as reviewed display inputs. Template
    # fragments and detector words do not establish coverage of a binary string.
    source = (root / CATALOG).read_text().split("NSString *SBLegacyFixedDisplayText(", 1)[0]
    return {json.loads(match[1]) for match in INPUT.finditer(source)}


def guard(root=ROOT):
    violations, approved, scanned = [], [], []
    for path in sorted((root / UI).glob("*")):
        if not path.is_file() or path.suffix not in {".h", ".m"}:
            continue
        relative = path.relative_to(root).as_posix()
        scanned.append(relative)
        source = path.read_text()
        spans = []
        if path.relative_to(root) == CATALOG:
            spans.extend((m.start(1), m.end(1), "Marked reviewed compatibility input")
                         for m in INPUT.finditer(source))
        for match in OBJC_STRING.finditer(source):
            if match[1] != "@":
                continue
            try:
                value = json.loads(match[2])
            except json.JSONDecodeError:
                continue  # An unrecognized literal receives no exemption.
            reason = ABI_LITERALS.get(relative, {}).get(value)
            if reason:
                spans.append((match.start(2), match.end(2), reason))
        for match in LEGACY.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            reason = next((why for start, end, why in spans if start <= match.start() < end), None)
            record = {"file": relative, "line": line}
            if reason:
                approved.append(dict(record, reason=reason))
            else:
                violations.append(dict(record, reason="Legacy reference outside an exact compatibility exemption"))
    if not scanned:
        violations.append({"file": str(UI), "line": 0, "reason": "No production UI sources scanned"})
    return {"schemaVersion": 1, "status": "PASS" if not violations else "FAIL",
            "scope": "Top-level production Objective-C sources in lucid/Presentation",
            "excluded": [{"path": "lucid/Presentation/Tests", "reason": "Synthetic original-host inputs and regressions; never shipped"}],
            "scannedFiles": scanned, "approvedReferences": approved, "violations": violations,
            "phoneAcceptance": "NOT_RUN"}


def legacy_binary_strings(raw):
    """Read only NUL-terminated UTF-8/UTF-16 strings containing inventory markers."""
    found = {}
    for match in re.finditer(rb"doritos|secretsauce", raw, re.IGNORECASE):
        start = raw.rfind(b"\0", 0, match.start()) + 1
        end = raw.find(b"\0", match.end())
        if end < 0 or end - start > 16384:
            continue
        try:
            text = raw[start:end].decode("utf-8")
        except UnicodeDecodeError:
            continue
        if all(c.isprintable() or c in "\n\r\t" for c in text):
            found[start] = ("utf8", text)
    pattern = rb"d\x00o\x00r\x00i\x00t\x00o\x00s\x00|s\x00e\x00c\x00r\x00e\x00t\x00s\x00a\x00u\x00c\x00e\x00"
    for match in re.finditer(pattern, raw, re.IGNORECASE):
        start = match.start()
        while start >= 2 and raw[start - 2:start] != b"\0\0" and match.start() - start < 16384:
            start -= 2
        end = match.start()
        while end + 2 <= len(raw) and raw[end:end + 2] != b"\0\0" and end - start < 16384:
            end += 2
        try:
            text = raw[start:end].decode("utf-16-le")
        except UnicodeDecodeError:
            continue
        if text and all(c.isprintable() or c in "\n\r\t" for c in text):
            found[start] = ("utf16le", text)
    return found


def classify(text, reviewed):
    if text in reviewed:
        return "reviewed_display_input"
    if (text.startswith(("/", "com.", "_", "v")) or "::" in text
            or (" " not in text and "\n" not in text)):
        return "compatibility_or_symbol_candidate"
    return "unreviewed_display_or_diagnostic_candidate"


def binary_inventory(path, reviewed):
    raw = path.read_bytes()
    matches = legacy_binary_strings(raw)
    records = [{"offset": hex(offset), "encoding": encoding,
                "textSHA256": digest(text.encode()), "length": len(text),
                "classification": classify(text, reviewed)}
               for offset, (encoding, text) in sorted(matches.items())]
    return {"name": path.name, "sha256": digest(raw), "executed": False,
            "markerStringCount": len(records), "uniqueMarkerStringCount": len({r["textSHA256"] for r in records}),
            "classificationCounts": dict(collections.Counter(r["classification"] for r in records)),
            "matches": records, "reachability": "NOT_ESTABLISHED_BY_STATIC_STRINGS"}


def metadata_inventory(path):
    raw = path.read_bytes()
    text = raw.decode("utf-8")
    lines = [number for number, line in enumerate(text.splitlines(), 1) if LEGACY.search(line)]
    return {"name": path.name, "sha256": digest(raw), "markerLineCount": len(lines),
            "markerLines": lines, "executed": False, "reachability": "NOT_ESTABLISHED_BY_METADATA"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--binary", action="append", type=Path, default=[])
    parser.add_argument("--metadata", action="append", type=Path, default=[])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    result = guard(args.root)
    reviewed = catalog_inputs(args.root)
    if args.binary:
        result["binaryInventory"] = [binary_inventory(p, reviewed) for p in args.binary]
    if args.metadata:
        result["metadataInventory"] = [metadata_inventory(p) for p in args.metadata]
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"{result['status']}: {len(result['scannedFiles'])} UI source files, {len(result['violations'])} unapproved legacy references; phone NOT_RUN")
        for record in result["violations"]:
            print(f"{record['file']}:{record['line']}: {record['reason']}")
        for record in result.get("binaryInventory", []):
            print(f"Static binary {record['name']}: {record['uniqueMarkerStringCount']} unique marker strings; not executed")
    return 1 if result["violations"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
