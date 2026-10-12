#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/tools/generate_app_registry.py" --check
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rbx-app-registry.XXXXXX")
trap 'rm -f "$temporary/test"; rmdir "$temporary"' EXIT
# Logos compiles .xm consumers as Objective-C++; preserve the same golden
# bundle/group outputs in both daemon/launcher and tweak language modes.
for language in objective-c objective-c++; do
    compiler=clang
    if [[ "$language" == objective-c++ ]]; then compiler=clang++; fi
    xcrun "$compiler" -x "$language" -fobjc-arc -fblocks -I"$ROOT/shared" -framework Foundation "$ROOT/tools/test_app_registry.m" -o "$temporary/test"
    "$temporary/test"
done
