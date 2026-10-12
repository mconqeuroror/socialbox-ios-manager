#!/usr/bin/env python3
"""Compare blocked pasteboard entry points against the actual build SDK contract."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
if len(sys.argv) > 1:
    sdk = Path(sys.argv[1])
elif sys.platform == "darwin":
    sdk = Path(subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip())
else:
    print("Pass an iOS SDK path, or run on the Mac build host.")
    sys.exit(77)

def method_selectors(text, terminator):
    methods = set()
    for sign, signature in re.findall(r"^([+-])\s*\([^)]*\)(.*?)" + terminator, text, re.M | re.S):
        labels = re.findall(r"\b(\w+)\s*:", signature)
        name = ":".join(labels) + ":" if labels else re.match(r"\s*(\w+)", signature).group(1)
        methods.add(sign + name)
    return methods

header = sdk / "System/Library/Frameworks/UIKit.framework/Headers/UIPasteboard.h"
text = header.read_text()
if "@interface UIPasteboard" not in text:
    header = sdk / "System/Library/PrivateFrameworks/UIKitCore.framework/Headers/UIPasteboard.h"
    text = header.read_text()
required = method_selectors(text, ";")
for property_text in re.findall(r"@property\s*(.*?);", text, re.S):
    declaration = property_text.split(" API_")[0].strip()
    name = re.search(r"(\w+)\s*$", declaration).group(1)
    sign = "+" if re.search(r"\bclass\b", declaration) else "-"
    getter = re.search(r"getter\s*=\s*(\w+)", declaration)
    required.add(sign + (getter.group(1) if getter else name))
    if not re.search(r"\breadonly\b", declaration):
        required.add(sign + "set" + name[0].upper() + name[1:] + ":")
source = (root / "tweak/Container/RBXPasteboardHooks.xm").read_text()
implemented = method_selectors(source, r"\{")
missing = sorted(required - implemented)
if len(required) < 40:
    raise SystemExit("Could not establish a complete UIPasteboard SDK interface")
if missing:
    raise SystemExit("Uncovered public pasteboard entry points: " + ", ".join(missing))
print(f"All {len(required)} public pasteboard entry points in {header.name} have blocking hooks")
