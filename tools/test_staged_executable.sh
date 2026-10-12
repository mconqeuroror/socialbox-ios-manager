#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-staged-executable.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
xcrun clang -fobjc-arc -Werror=return-type -I"$ROOT/shared" -framework Foundation "$ROOT/tools/test_staged_executable.m" -o "$fixture/test"
"$fixture/test" "$fixture"
