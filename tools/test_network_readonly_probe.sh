#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-network-readonly.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  "$repo_dir/tools/test_network_readonly_probe.c" -o "$test_dir/test"
"$test_dir/test"
