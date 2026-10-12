#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
run_dir=$(mktemp -d -t socialbox-container-configuration)
trap 'rm -rf "$run_dir"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-nullability-completeness \
  -framework Foundation lucid/Containers/LBXContainerConfiguration.m \
  lucid/tests/container_configuration.m -o "$run_dir/container-configuration"
"$run_dir/container-configuration"
