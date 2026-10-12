#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/rbx-private-draft.XXXXXX")
trap 'rm -f "$BUILD/test"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -framework Foundation -framework Security "$ROOT/tools/test_identity_draft_store.m" -o "$BUILD/test"
"$BUILD/test"
