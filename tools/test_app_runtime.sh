#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
build=$(mktemp -d "${TMPDIR:-/tmp}/rbx-app-runtime.XXXXXX")
trap 'rm -rf "$build"' EXIT
python3 - "$ROOT" "$build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'tweak/AppAttest/RBXAppAttestHooks.xm').read_text()
start = source.index('static BOOL RBXDeviceCheckShouldBlock(')
end = source.index('static void RBXLogAttestEntry(', start)
(build / 'app-attest-policy.inc').write_text(source[start:end])
for path in (root / 'tweak').rglob('*.xm'):
    source = path.read_text()
    if '%ctor {' in source:
        assert '%ctor {\n    @autoreleasepool {\n        if (!RBXAppRuntimeHooksEnabled()) return;' in source, path
source = (root / 'tweak/Network/RBXRedditAPIHooks.xm').read_text()
installer = source[source.index('BOOL RBXInstallRedditAPIHooks('):source.index('%ctor {')]
assert installer.index('RBXAppRuntimeWirePolicyAudited') < installer.index('%init;')
entry = (root / 'tweak/RedditBox.xm').read_text()
assert 'installed[@"defaults-wire"] = @NO;' in entry
manager = (root / 'tweak/Container/RBXContainerManager.xm').read_text()
start = manager.index('static BOOL RBXCloneProfileHasSafeShape(')
end = manager.index('static BOOL RBXCloneEntitlementsMatchProfile(', start)
(build / 'app-fallback-profile.inc').write_text(manager[start:end])
assert 'RBXAppRuntimeProfileMatchesBundle(dict, actualBundle)' in manager
assert 'RBXGenerateFallbackProfile(_containerId, actualApp)' in manager
assert 'Executable' in (root / 'tweak/RedditBox.plist').read_text()
assert '"Facebook"' in (root / 'tweak/RedditBox.plist').read_text()
PY
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -I"$build" -I"$ROOT/shared" \
    -I"$ROOT/tweak/Common" -I"$ROOT/tweak/Container" -framework Foundation \
    "$ROOT/tools/test_app_runtime.m" "$ROOT/tweak/Common/RBXProfile.m" \
    "$ROOT/shared/RBXMGOverrides.m" -o "$build/test"
"$build/test"
