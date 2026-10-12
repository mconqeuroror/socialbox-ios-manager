#!/usr/bin/env bash
# Host smoke for the source-rebuilt SocialBoxHelper (Theos rootless tool).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/lucid/Helper"
THEOS="${THEOS:-/Users/martin/Documents/Codex/2026-09-30/i/work/socialbox-import/work/theos}"
LDID="${LDID:-/Users/martin/Documents/Codex/2026-09-30/i/work/socialbox-import/work/local-tools/bin/ldid}"
TARGET="${HELPER_TARGET:-iphone:clang:26.5:15.0}"

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

test -d "$THEOS" || die "THEOS missing at $THEOS"
test -x "$LDID" || die "LDID missing at $LDID"
test -f "$HELPER/Makefile" || die "Helper Makefile missing"

echo "== compile/link SocialBoxHelper =="
make -C "$HELPER" clean >/dev/null
make -C "$HELPER" \
  THEOS="$THEOS" \
  TARGET="$TARGET" \
  FINALPACKAGE=1 \
  TARGET_CODESIGN="$LDID" \
  TARGET_CODESIGN_FLAGS=-S

BIN=""
for candidate in \
  "$HELPER/.theos/obj/SocialBoxHelper" \
  "$HELPER/.theos/obj/debug/SocialBoxHelper"
do
  if [[ -f "$candidate" ]]; then BIN="$candidate"; break; fi
done
[[ -n "$BIN" ]] || die "built SocialBoxHelper binary not found"
pass "linked $BIN"

echo "== identity strings =="
for needle in \
  "com.socialbox.helper.xpc" \
  "com.socialbox.helper" \
  "s_o_c_i_a_l_b_o_x" \
  "___SocialBox_Containers" \
  "/var/jb/usr/libexec/SocialBoxHelper"
do
  strings "$BIN" | rg -F -q -- "$needle" || die "missing binary string: $needle"
  pass "binary contains $needle"
done

echo "== doritos ban (binary + source tree + plists) =="
if strings "$BIN" | rg -i -q doritos; then
  strings "$BIN" | rg -i doritos >&2 || true
  die "doritos string present in SocialBoxHelper"
fi
pass "binary doritos scan: ZERO matches"

if rg -i -q doritos "$HELPER" --glob '!**/.theos/**'; then
  rg -i doritos "$HELPER" --glob '!**/.theos/**' >&2 || true
  die "doritos string present under lucid/Helper source"
fi
pass "helper source doritos scan: ZERO matches"

for plist in \
  "$HELPER/com.socialbox.helper.plist" \
  "$HELPER/layout/Library/LaunchDaemons/com.socialbox.helper.plist"
do
  test -f "$plist" || die "missing $plist"
  if rg -i -q doritos "$plist"; then
    die "doritos string present in $plist"
  fi
  /usr/bin/plutil -lint "$plist" >/dev/null
  Label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")"
  Program="$(/usr/libexec/PlistBuddy -c 'Print :Program' "$plist")"
  Mach="$(/usr/libexec/PlistBuddy -c 'Print :MachServices:com.socialbox.helper.xpc' "$plist")"
  [[ "$Label" == "com.socialbox.helper" ]] || die "bad Label in $plist"
  [[ "$Program" == "/var/jb/usr/libexec/SocialBoxHelper" ]] || die "bad Program in $plist"
  [[ "$Mach" == "true" ]] || die "bad MachServices in $plist"
  pass "plist ok: $plist"
done

echo "== host agrp/path unit (clang) =="
mkdir -p "$HELPER/.theos"
HOST_SRC="$HELPER/.theos/host_agrp_smoke.m"
HOST_BIN="$HELPER/.theos/host_agrp_smoke"
cat >"$HOST_SRC" <<EOF
#import <Foundation/Foundation.h>
#import "$ROOT/lucid/Switching/LBXSocialBoxProduct.h"
#include <string.h>
#include <stdio.h>
int main(void) {
  @autoreleasepool {
    NSString *agrp = [NSString stringWithFormat:@"%%.%s.%lld", LBX_SOCIALBOX_KEYCHAIN_TOKEN, 2LL];
    if (![agrp isEqualToString:@"%.s_o_c_i_a_l_b_o_x.2"]) return 2;
    if (strcmp(LBX_SOCIALBOX_HELPER_MACH, "com.socialbox.helper.xpc") != 0) return 3;
    if (strcmp(LBX_SOCIALBOX_HELPER_LABEL, "com.socialbox.helper") != 0) return 4;
    if (strcmp(LBX_SOCIALBOX_HELPER_PATH, "/var/jb/usr/libexec/SocialBoxHelper") != 0) return 5;
    if (strstr(LBX_SOCIALBOX_KEYCHAIN_TOKEN, "d_o_r") != NULL) return 6;
    puts("host_agrp_smoke_ok");
    return 0;
  }
}
EOF
clang -fobjc-arc -framework Foundation -o "$HOST_BIN" "$HOST_SRC"
"$HOST_BIN" | rg -q host_agrp_smoke_ok || die "host agrp smoke failed"
pass "host agrp/path smoke"

SIZE="$(stat -f%z "$BIN")"
SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
echo "== artifact =="
echo "path=$BIN"
echo "size=$SIZE"
echo "sha256=$SHA"
echo "ALL HOST CHECKS PASSED"
