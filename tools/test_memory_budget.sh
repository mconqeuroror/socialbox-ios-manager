#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-memory-test.XXXXXX")
trap 'rm -f "$BUILD/test-memory-budget"; rmdir "$BUILD"' EXIT HUP INT TERM
cc -std=c11 -Wall -Wextra -Werror "$ROOT/tools/test_memory_budget.c" -o "$BUILD/test-memory-budget"
"$BUILD/test-memory-budget"
