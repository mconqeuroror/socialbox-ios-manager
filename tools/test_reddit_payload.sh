#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-payload-test.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
python3 - "$ROOT" "$BUILD" <<'PY'
from pathlib import Path
import sys
root,build=map(Path,sys.argv[1:])
s=(root/'tweak/Network/RBXRedditAPIHooks.xm').read_text()
# Builder order is not a dispatch boundary: signatures/URL can be added last.
assert '%hook NSMutableURLRequest' not in s, 'request assignment must preserve original headers until destination/signature-aware dispatch'
def section(start,end):
 assert s.count(start)==1 and s.count(end)==1
 return s[s.index(start):s.index(end)]
# Compile the shipped Foundation-only functions verbatim, without iOS hook
# adapters. This is a behavioral test of production code, not a copied model.
code=section('static BOOL RBXIsRedditAPIHost(', 'static BOOL RBXIsPassThroughKey(')
code+=section('static BOOL RBXIsPassThroughKey(', 'static BOOL RBXLooksLikeJSONObject(')
code+=section('static BOOL RBXLooksLikeJSONObject(', 'static void RBXRecordAuthenticatedActivity(')
code+=section('static NSURLRequest *RBXRewriteRequest(', '// --- UserDefaults isolation')
s=(root/'tweak/Network/RBXProxyHooks.xm').read_text()
code+=section('static BOOL RBXCriticalHostAllowed(', 'static BOOL RBXThirdPartyNetworkAllowed(')
(build/'reddit-json.inc').write_text(code)
PY
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-function \
 -I"$BUILD" -I"$ROOT/tweak/Common" -I"$ROOT/shared" -framework Foundation \
 "$ROOT/tools/test_reddit_payload.m" "$ROOT/tweak/Common/RBXProfile.m" \
 "$ROOT/shared/RBXMGOverrides.m" -o "$BUILD/test-reddit-payload"
"$BUILD/test-reddit-payload"
