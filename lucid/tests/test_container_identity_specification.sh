#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -DLBX_CONTAINER_IDENTITY_SPECIFICATION_TESTING=1 \
  -framework Foundation lucid/Containers/LBXContainerConfiguration.m \
  lucid/Containers/LBXContainerIdentitySpecification.m lucid/tests/container_identity_specification.m \
  -o "$temporary/test-identity-specification"
"$temporary/test-identity-specification"
