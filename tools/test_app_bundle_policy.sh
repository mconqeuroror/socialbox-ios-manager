#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/rbx-app-bundle.XXXXXX")
trap 'rm -f "$BUILD/test"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -I"$ROOT/shared" -framework Foundation "$ROOT/tools/test_app_bundle_policy.m" -o "$BUILD/test"
"$BUILD/test"
