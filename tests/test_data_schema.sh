#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/redditbox-data-schema.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-function \
  -Idaemon -Ishared -framework Foundation \
  tests/test_data_schema.m daemon/RBXDataMigration.m daemon/RBXProfileIO.m daemon/RBXCentralStore.m \
  -o "$temporary/test-data-schema"
"$temporary/test-data-schema"
