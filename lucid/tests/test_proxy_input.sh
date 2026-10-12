#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
run_dir=$(mktemp -d -t socialbox-proxy-input)
trap 'rm -rf "$run_dir"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-nullability-completeness \
  -framework Foundation -framework CFNetwork lucid/ProxyInput/LBXProxyInput.m shared/RBXHTTPProxy.m \
  lucid/tests/proxy_input.m -o "$run_dir/proxy-input"
"$run_dir/proxy-input"
