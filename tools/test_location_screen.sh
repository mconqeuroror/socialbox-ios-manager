#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/rbx-location-screen.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc -fblocks -framework Foundation -I"$ROOT/launcher" "$ROOT/tools/test_location_screen.m" -o "$TEST_DIR/test"
"$TEST_DIR/test"
