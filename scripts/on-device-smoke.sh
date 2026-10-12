#!/bin/sh
set -eu

LEASE=/var/mobile/Library/Preferences/com.redditbox.network-lease.plist
STATUS=/var/mobile/Library/Preferences/com.redditbox.firewall-status.plist
PROFILE_DIR=/var/mobile/Library/Preferences/com.redditbox.profiles
LAUNCHER_STATE=/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist

MODE=${1:-status}
case "$MODE" in setup|launcher|source|profiles|clones|status|production|logs) ;;
  *) echo "Usage: $0 {setup|launcher|source|profiles|clones|status|production|logs REQUEST GENERATION CLONE_PID}" >&2; exit 2 ;;
esac

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ "$(id -u)" = 0 ] || fail "run as root"
pgrep -x redditboxd >/dev/null || fail "redditboxd is not running"
pass "daemon running"

[ -f "$LEASE" ] || fail "network lease missing"
case "$MODE" in status|production|logs)
[ -f "$STATUS" ] || fail "system firewall status missing"

LEASE_STATE="$(plutil -extract state raw "$LEASE" 2>/dev/null || true)"
LEASE_GEN="$(plutil -extract generation raw "$LEASE" 2>/dev/null || true)"
FW_STATE="$(plutil -extract state raw "$STATUS" 2>/dev/null || true)"
FW_GEN="$(plutil -extract generation raw "$STATUS" 2>/dev/null || true)"
FW_ENFORCED="$(plutil -extract enforced raw "$STATUS" 2>/dev/null || true)"
FW_SCOPE="$(plutil -extract scope raw "$STATUS" 2>/dev/null || true)"

[ "$FW_ENFORCED" = "true" ] || fail "packet firewall is not enforced"
[ "$LEASE_STATE" = "$FW_STATE" ] || fail "lease/firewall state mismatch"
[ "$LEASE_GEN" = "$FW_GEN" ] || fail "lease/firewall generation mismatch"
pass "lease and packet firewall agree ($LEASE_STATE)"

if [ "${1:-status}" = "production" ]; then
  [ "$FW_SCOPE" = "per-app" ] || fail "supervised per-app VPN scope is not active"
  pass "supervised per-app VPN scope active"
fi

if [ "$MODE" = "logs" ]; then
  [ "$#" = 4 ] || fail "logs requires a full request ID, generation and live clone PID"
  case "$2$3" in *[!a-fA-F0-9-]*|'') fail "request and generation must be UUIDs" ;; esac
  [ "${#2}" = 36 ] && [ "${#3}" = 36 ] || fail "use full UUIDs, not shortened log IDs"
  case "$4" in *[!0-9]*|'') fail "clone PID must be numeric" ;; esac
  REPORT="$(log show --last 15m --style compact --predicate 'process == "redditboxd"')" ||
    fail "system log query failed"
  CHECKER="$(dirname "$0")/smoke-log-order.awk"
  [ -f "$CHECKER" ] || fail "generation log checker is missing from the package"
  printf '%s\n' "$REPORT" | awk -v request="$2" -v generation="$3" -v clonePID="$4" -f "$CHECKER" ||
    fail "final authorization evidence did not match"
fi
;;
esac

if [ "$MODE" = "setup" ]; then
  state="$(plutil -extract state raw "$LEASE" 2>/dev/null || true)"
  [ "$state" = "closed" ] || fail "first-run setup must keep local traffic CLOSED"
  [ -f "$LAUNCHER_STATE" ] || fail "launcher state missing"
  pass "local CLOSED and launcher state exist; proxy/VPN/source are not prerequisites for setup"
fi

if [ "${1:-status}" = "profiles" ]; then
  python3 /var/jb/usr/share/redditbox/isolation_audit.py --profiles-dir "$PROFILE_DIR"
fi

if [ "${1:-status}" = "clones" ]; then
  count=0
  seen_data="|"
  for profile in "$PROFILE_DIR"/*.json; do
    [ -e "$profile" ] || continue
    bundle_id="$(plutil -extract app.bundleIdentifier raw "$profile" 2>/dev/null || true)"
    bundle_path="$(plutil -extract app.bundlePath raw "$profile" 2>/dev/null || true)"
    keychain_group="$(plutil -extract app.keychainAccessGroup raw "$profile" 2>/dev/null || true)"
    architecture="$(plutil -extract app.architecture raw "$profile" 2>/dev/null || true)"
    [ -n "$bundle_id" ] || fail "$profile has no clone bundle identifier"
    [ "$architecture" = "clonedApp-v2" ] || fail "$bundle_id is not installd clone v2"
    [ -d "$bundle_path" ] || fail "$bundle_id clone bundle is missing"
    case "$bundle_path" in
      /var/containers/Bundle/Application/*|/var/mobile/Containers/Bundle/Application/*) ;;
      *) fail "$bundle_id is not installed in an installd-owned bundle container" ;;
    esac
    actual_id="$(plutil -extract CFBundleIdentifier raw "$bundle_path/Info.plist" 2>/dev/null || true)"
    [ "$actual_id" = "$bundle_id" ] || fail "$bundle_id Info.plist mismatch"
    hidden_tag="$(plutil -extract SBAppTags.0 raw "$bundle_path/Info.plist" 2>/dev/null || true)"
    launcher_only="$(plutil -extract RBXLauncherOnly raw "$bundle_path/Info.plist" 2>/dev/null || true)"
    [ "$hidden_tag" = "hidden" ] || fail "$bundle_id has no SpringBoard hidden tag"
    [ "$launcher_only" = "true" ] || fail "$bundle_id has no launcher-only marker"
    [ -f "$bundle_path/.redditbox-clone.plist" ] || fail "$bundle_id metadata missing"
    installer="$(plutil -extract installer raw "$bundle_path/.redditbox-clone.plist" 2>/dev/null || true)"
    [ "$installer" = "appinst" ] || fail "$bundle_id bypassed installd/appinst"
    [ ! -f "$bundle_path/embedded.mobileprovision" ] || fail "$bundle_id retained provisioning"
    executable="$(plutil -extract CFBundleExecutable raw "$bundle_path/Info.plist")"
    entitlements="/tmp/redditbox-entitlements-$$.plist"
    ldid -e "$bundle_path/$executable" >"$entitlements" 2>/dev/null ||
      fail "$bundle_id signature cannot be inspected"
    grep -q "$keychain_group" "$entitlements" || fail "$bundle_id keychain group mismatch"
    if grep -Eq 'application-groups|aps-environment|ubiquity|icloud' "$entitlements"; then
      fail "$bundle_id retained a shared/cloud/push entitlement"
    fi
    rm -f "$entitlements"
    data_container=""
    for metadata in /var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist; do
      [ -f "$metadata" ] || continue
      metadata_id="$(plutil -extract MCMMetadataIdentifier raw "$metadata" 2>/dev/null || true)"
      if [ "$metadata_id" = "$bundle_id" ]; then
        data_container="${metadata%/.com.apple.mobile_container_manager.metadata.plist}"
        break
      fi
    done
    [ -n "$data_container" ] || fail "$bundle_id has no OS data container"
    case "$seen_data" in
      *"|$data_container|"*) fail "$bundle_id shares an OS data container" ;;
    esac
    seen_data="${seen_data}${data_container}|"
    count=$((count + 1))
  done
  [ "$count" -ge 1 ] || fail "no cloned profiles found"
  pass "$count clone bundle(s) have isolated IDs and stripped entitlements"
fi

if [ "${1:-status}" = "launcher" ]; then
  [ -d /var/jb/Applications/RedditBox.app ] || fail "RedditBox launcher is not installed"
  launcher_id="$(plutil -extract CFBundleIdentifier raw \
    /var/jb/Applications/RedditBox.app/Info.plist 2>/dev/null || true)"
  [ "$launcher_id" = "com.redditbox.launcher" ] || fail "launcher bundle ID mismatch"
  firewall_hidden="$(plutil -extract SBAppTags.0 raw \
    /var/jb/Applications/RedditBoxFirewall.app/Info.plist 2>/dev/null || true)"
  [ "$firewall_hidden" = "hidden" ] || fail "firewall host is visible on SpringBoard"
  [ -f "$LAUNCHER_STATE" ] || fail "daemon has not published launcher state"
  plutil -extract containers xml1 -o - "$LAUNCHER_STATE" >/dev/null 2>&1 ||
    fail "launcher state has no container inventory"
  [ ! -e /var/jb/Library/MobileSubstrate/DynamicLibraries/RedditBoxSB.dylib ] ||
    fail "legacy SpringBoard hook is still installed"
  pass "single launcher installed, daemon state published, SpringBoard hook absent"
fi

if [ "$MODE" = "source" ]; then
  [ -d /var/mobile/Library/RedditBox/Source/Reddit.app ] ||
    fail "private Reddit source cache is missing"
  if uicache -l 2>/dev/null | grep -q 'com\.reddit\.Reddit'; then
    fail "visible source Reddit app is still registered"
  fi
  pass "private source cache present and visible source retired"
fi

echo "Smoke status complete. Continue with docs/on-device-smoke-checklist.md."
