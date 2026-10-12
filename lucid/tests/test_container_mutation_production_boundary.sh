#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-mutation-production.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
checks=0
for architecture in arm64 arm64e; do
  for source in lucid/Containers/LBXContainerMutationIPC.m lucid/Containers/LBXContainerMutationClient.m lucid/Authorization/LBXLicensePeer.m; do
    object="$temporary/$architecture-$(basename "$source").o"
    xcrun --sdk iphoneos clang -target "$architecture-apple-ios15.0" -isysroot "$sdk" \
      -fobjc-arc -fblocks -Wall -Wextra -Werror -c "$source" -o "$object"
    checks=$((checks+1))
    # Private test TU substitutions must never occur in production objects.
    xcrun nm "$object" > "$object.symbols"
    strings "$object" > "$object.strings"
    if rg -i 'Fixture|TestProvider|testUse|testAfter|synthetic|LBX_CONTAINER_MUTATION_TESTING' "$object.symbols" "$object.strings"; then
      exit 1
    fi
    checks=$((checks+1))
  done
done
echo "PASS: $checks production architecture/provider-boundary assertions, 0 failures"
