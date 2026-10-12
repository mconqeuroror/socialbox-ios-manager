#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-creation-draft.XXXXXX")
trap 'rm -f "$BUILD/test"; rmdir "$BUILD"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I"$ROOT/daemon" -framework Foundation "$ROOT/tools/test_creation_draft_store.m" -o "$BUILD/test"
"$BUILD/test"
