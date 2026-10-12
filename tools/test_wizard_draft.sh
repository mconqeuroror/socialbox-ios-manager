#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-wizard-test.XXXXXX")
trap 'rm -f "$BUILD/test-wizard"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -framework Foundation \
    "$ROOT/tools/test_wizard_draft.m" -o "$BUILD/test-wizard"
"$BUILD/test-wizard"
