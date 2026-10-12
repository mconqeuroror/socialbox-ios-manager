#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
run_dir=$(mktemp -d -t socialbox-drain)
trap 'rm -rf "$run_dir"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation \
    tools/test_recovered_process_drain.m lucid/Switching/LBXProcessDrain.m lucid/Switching/LBXManagedApplications.m -o "$run_dir/test"
"$run_dir/test"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -framework Foundation \
    tools/test_recovered_darwin_drain.m lucid/Switching/LBXProcessDrain.m lucid/Switching/LBXManagedApplications.m -o "$run_dir/adapter-test"
"$run_dir/adapter-test"
