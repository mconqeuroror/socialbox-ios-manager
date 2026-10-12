#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rbx-operator-wording.XXXXXX")
trap 'rm -f "$temporary/test"; rmdir "$temporary"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -I"$ROOT/launcher" -framework Foundation \
    "$ROOT/tools/test_operator_wording.m" -o "$temporary/test"
"$temporary/test"
