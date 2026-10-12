#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rbx-launch-safety.XXXXXX")
trap 'rm -f "$temporary/test"; rmdir "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -I"$ROOT/shared" -framework Foundation "$ROOT/tools/test_launch_safety.m" -o "$temporary/test"
"$temporary/test"
