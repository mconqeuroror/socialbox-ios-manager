#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-pf-kernel.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I"$repo_dir/experimental/pf" -framework Foundation \
  "$repo_dir/experimental/pf/RBXPFPolicyPlan.m" "$repo_dir/experimental/pf/RBXPFKernelPolicy.m" \
  "$repo_dir/tools/test_pf_kernel_policy.m" -o "$test_dir/test"
"$test_dir/test"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I"$repo_dir/experimental/pf" -framework Foundation \
  "$repo_dir/experimental/pf/RBXPFPolicyPlan.m" "$repo_dir/experimental/pf/RBXPFKernelPolicy.m" \
  "$repo_dir/tools/pf_policy_readback.m" -o "$test_dir/readback"
python3 "$repo_dir/tools/test_pf_policy_readback.py" "$test_dir/readback"
for arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$arch-apple-ios15.0" -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -I"$repo_dir/experimental/pf" -fsyntax-only "$repo_dir/experimental/pf/RBXPFKernelPolicy.m" \
    "$repo_dir/tools/pf_policy_readback.m"
done
