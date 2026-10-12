#!/usr/bin/env bash
set -euo pipefail
# This lane compiles our own launcher, daemon, tweak and firewall. It never
# packages the recovered engine, patches its authorization, or publishes it.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${RBX_RELEASE_VERSION:?Set an explicit private candidate version}"
: "${LICENSE_PUBLIC_KEY_FILE:?Set the existing deployment public PEM}"
SCHEME="${RBX_PACKAGE_SCHEME:-rootless}"
case "$SCHEME" in
  rootless) ARCH=iphoneos-arm64 ;;
  rootful) ARCH=iphoneos-arm ;;
  *) echo "Use rootless or rootful" >&2; exit 1 ;;
esac
bash "$ROOT/scripts/build-mac.sh"
python3 "$ROOT/tools/check_source_socialbox_package.py" \
  "$ROOT/packages/com.redditbox_${RBX_RELEASE_VERSION}_${ARCH}.deb" \
  --version "$RBX_RELEASE_VERSION" --scheme "$SCHEME" \
  --pin-header "$ROOT/build/generated/RBXLicensePublicKey.h" \
  --output "$ROOT/build/source-socialbox-${SCHEME}.json"
echo "Source package verified. Review the separate recovered-to-source migration before installation."
