#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/lbx-assessment.XXXXXX")
trap 'rm -f "$scratch/test"; rmdir "$scratch"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation \
  "$ROOT/lucid/Diagnostics/LBXIsolationAssessment.m" "$ROOT/tools/test_lucid_isolation_assessment.m" -o "$scratch/test"
"$scratch/test"
