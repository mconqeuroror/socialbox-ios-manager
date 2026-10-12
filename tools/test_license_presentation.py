#!/usr/bin/env python3
"""Execute shipped C time boundaries portably; Foundation type checks run on Mac."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
header = (ROOT / "shared/RBXLicensePresentation.h").read_text(encoding="utf-8")


def compiler():
    if os.environ.get("CC"):
        return shlex.split(os.environ["CC"], posix=os.name != "nt")
    clang = shutil.which("clang") or shutil.which("cc")
    if clang:
        return [clang]
    zig = shutil.which("zig")
    local_zig = ROOT.parent / "native-check-tools/zig-x86_64-windows-0.14.1/zig.exe"
    if zig or local_zig.exists():
        return [zig or str(local_zig), "cc"]
    raise RuntimeError("Set CC to a C compiler or install clang/zig for actual boundary tests")


program = r'''
#include "RBXLicensePresentation.h"
#include <stdio.h>
int main(void) {
    const struct { double now, published, expires; int expected; } cases[] = {
        {1000, 1000, 2000, RBXLicensePresentationValid},
        {1000, 990, 2000, RBXLicensePresentationValid},
        {1000, 989.999, 2000, RBXLicensePresentationStalePublication},
        {1000, 1002, 2000, RBXLicensePresentationValid},
        {1000, 1002.001, 2000, RBXLicensePresentationFuturePublication},
        {1000, 1000, 1000, RBXLicensePresentationExpired},
        {1000, 1000, 999, RBXLicensePresentationExpired},
        {1000, 1000, 1000.001, RBXLicensePresentationValid},
        {NAN, 1000, 2000, RBXLicensePresentationInvalidClock},
        {INFINITY, 1000, 2000, RBXLicensePresentationInvalidClock},
        {-1, 1000, 2000, RBXLicensePresentationInvalidClock},
        {1000, NAN, 2000, RBXLicensePresentationMissingPublication},
        {1000, INFINITY, 2000, RBXLicensePresentationMissingPublication},
        {1000, 0, 2000, RBXLicensePresentationMissingPublication},
        {1000, -1, 2000, RBXLicensePresentationMissingPublication},
        {1000, 1000, NAN, RBXLicensePresentationMissingExpiry},
        {1000, 1000, INFINITY, RBXLicensePresentationMissingExpiry},
        {1000, 1000, 0, RBXLicensePresentationMissingExpiry},
        {1000, 1000, -1, RBXLicensePresentationMissingExpiry},
    };
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        int actual = RBXLicensePresentationWindow(cases[i].now, cases[i].published, cases[i].expires);
        if (actual != cases[i].expected) {
            fprintf(stderr, "boundary %u: expected %d, got %d\n", i, cases[i].expected, actual);
            return 1;
        }
    }
    puts("19 shipped license presentation time boundaries passed");
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix="rbx-license-presentation-") as folder:
    directory = Path(folder)
    source = directory / "boundaries.c"
    source.write_text(program, encoding="utf-8")
    executable = directory / ("boundaries.exe" if os.name == "nt" else "boundaries")
    command = compiler() + ["-std=c11", "-I", str(ROOT / "shared"), str(source), "-o", str(executable)]
    subprocess.run(command, check=True, capture_output=True)
    subprocess.run([str(executable)], check=True)

assert "CFBooleanGetTypeID" in header, "Boolean timestamps must be rejected"
assert 'RBXLicensePresentationFlag(license[@"unlocked"])' in header
assert 'RBXLicensePresentationNumber(document[@"updatedAt"])' in header
assert 'RBXLicensePresentationNumber(license[@"expiresAt"])' in header
assert 'state[@"unlocked"] = @(granted)' in header
assert "NSDate" not in header, "The caller supplies time so boundary tests are deterministic"
for forbidden in ("writeToFile", "NSUserDefaults", "SecItem", "NSURLSession", 'license[@"token"]', 'license[@"key"]'):
    assert forbidden not in header, forbidden
print("presentation safe-field contracts passed; run Foundation fixture tests on Mac")
