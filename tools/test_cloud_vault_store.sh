#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/rbx-cloud-vault.XXXXXX")
trap 'rm -f "$BUILD/test"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -framework Foundation -framework Security "$ROOT/tools/test_cloud_vault_store.m" -o "$BUILD/test"
"$BUILD/test"
