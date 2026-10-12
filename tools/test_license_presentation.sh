#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
xcrun clang -fobjc-arc -fblocks -Ishared -framework Foundation tools/test_license_presentation.m -o "$build_dir/test"
"$build_dir/test"
