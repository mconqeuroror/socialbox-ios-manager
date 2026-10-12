#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0 PROFILE_ID [COUNTRY]" >&2
  exit 77
fi

profile_id="${1:-}"
country="${2:-US}"
if [ -z "$profile_id" ]; then
  echo "usage: $0 PROFILE_ID [COUNTRY]" >&2
  exit 64
fi
if pgrep -x Reddit >/dev/null 2>&1; then
  echo "Close/switch out of every Reddit clone before provisioning" >&2
  exit 75
fi

prefix=""
[ -x /var/jb/usr/bin/redditboxd ] && prefix="/var/jb"
daemon="$prefix/usr/bin/redditboxd"
ldid="$prefix/usr/bin/ldid"
appinst="$prefix/usr/bin/appinst"
zip_bin="$prefix/usr/bin/zip"

if [ ! -x "$daemon" ]; then
  echo "redditboxd is not installed" >&2
  exit 69
fi
if [ ! -x "$ldid" ] && [ ! -x /usr/bin/ldid ]; then
  echo "ldid is required; clone was not created" >&2
  exit 69
fi
if [ ! -x "$appinst" ] && [ ! -x /usr/bin/appinst ]; then
  echo "appinst is required so installd creates the OS containers" >&2
  exit 69
fi
if [ ! -x "$zip_bin" ] && [ ! -x /usr/bin/zip ]; then
  echo "zip is required to package the staged clone IPA" >&2
  exit 69
fi

RBX_KEEP_CLONE_IPA=1 "$daemon" provision-clone "$profile_id" "$country"

echo "Clone provisioned. It remains network-blocked until:"
echo "  1. the RedditBox NetworkExtension is enabled;"
echo "  2. supervised MDM maps this managed clone to the per-app VPN;"
echo "  3. the profile is opened through RedditBox (never from its icon first)."
echo "Signed IPA for MDM upload (new clones):"
echo "  /var/mobile/Library/RedditBox/IPAs/com.redditbox.profile.*.ipa"
echo "Delete the exported IPA after MDM adoption to reclaim space."
