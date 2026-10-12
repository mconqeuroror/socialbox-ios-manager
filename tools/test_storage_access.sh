#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-storage-access.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
xcrun clang -fobjc-arc -fblocks -Werror=return-type -Wno-nullability-completeness -I"$ROOT/shared" -I"$ROOT/daemon" -I"$ROOT/tools/fixtures/storage_gate" -framework Foundation "$ROOT/tools/test_storage_access.m" -o "$fixture/test"
mkdir "$fixture/data"
"$fixture/test" "$fixture/data"
