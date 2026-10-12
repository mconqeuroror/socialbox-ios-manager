#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-pf-plan.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I"$repo_dir/experimental/pf" -framework Foundation \
  "$repo_dir/experimental/pf/RBXPFPolicyPlan.m" "$repo_dir/tools/test_pf_policy_plan.m" \
  -o "$test_dir/test"
"$test_dir/test"
