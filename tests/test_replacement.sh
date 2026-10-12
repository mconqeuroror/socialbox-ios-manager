#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/redditbox-replacement.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter \
  -Ishared -framework Foundation -framework CoreFoundation tests/test_replacement.m -o "$temporary/test-replacement"
"$temporary/test-replacement"
