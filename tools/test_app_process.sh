#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rbx-app-process.XXXXXX")
trap 'rm -f "$temporary/test"; rmdir "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wno-nullability-completeness -I"$ROOT/shared" -I"$ROOT/daemon" \
    -framework Foundation "$ROOT/tools/test_app_process.m" -o "$temporary/test"
"$temporary/test"
