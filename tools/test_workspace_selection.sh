#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I"$ROOT/shared" -framework Foundation "$ROOT/tools/test_workspace_selection.m" -o "$TMP/test"
"$TMP/test"
