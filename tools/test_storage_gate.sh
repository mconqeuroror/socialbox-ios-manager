#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-storage-gate.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
xcrun clang -Wall -Wextra -Werror -Wno-unused-parameter -include string.h -I"$ROOT/tools/fixtures/storage_gate" "$ROOT/tools/test_storage_gate.c" -o "$temporary/test"
mkdir "$temporary/homes"
"$temporary/test" "$temporary/homes"
