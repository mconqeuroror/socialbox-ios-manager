#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
run_dir=$(mktemp -d -t rbx-process-identity)
trap 'rm -rf "$run_dir"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-macro-redefined -Ishared -framework Foundation tools/test_process_identity.m -o "$run_dir/test"
"$run_dir/test"
