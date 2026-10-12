#!/bin/sh
# Device-side install for the SocialBox container-switching release. No secrets.
set -e
echo BEGIN_INSTALL
PATH="/var/jb/bin:/var/jb/usr/bin:/usr/bin:/bin:$PATH"
export PATH

STAGE=/tmp/socialbox-stage-rebuild
mkdir -p "$STAGE"
rm -rf "$STAGE"/*
tar -C "$STAGE" -xzf /tmp/socialbox-stage-rebuild.tgz
ls -la "$STAGE"

mkdir -p /var/jb/Applications /var/jb/usr/libexec /var/jb/usr/local/bin /var/jb/Library/LaunchDaemons

launchctl bootout system/com.socialbox.helper 2>/dev/null || true

rm -rf /var/jb/Applications/SocialBox.app
cp -a "$STAGE/Applications/SocialBox.app" /var/jb/Applications/
cp -f "$STAGE/usr/libexec/SocialBoxHelper" /var/jb/usr/libexec/SocialBoxHelper
cp -f "$STAGE/usr/libexec/socialbox-drain-service" /var/jb/usr/libexec/socialbox-drain-service
cp -f "$STAGE/usr/local/bin/SocialBoxCLI" /var/jb/usr/local/bin/SocialBoxCLI
cp -f "$STAGE/Library/LaunchDaemons/com.socialbox.helper.plist" /var/jb/Library/LaunchDaemons/com.socialbox.helper.plist
chmod 755 /var/jb/usr/libexec/SocialBoxHelper /var/jb/usr/libexec/socialbox-drain-service /var/jb/usr/local/bin/SocialBoxCLI /var/jb/Applications/SocialBox.app/SocialBox
chown root:wheel /var/jb/Applications/SocialBox.app/SocialBox /var/jb/usr/libexec/SocialBoxHelper /var/jb/usr/libexec/socialbox-drain-service /var/jb/usr/local/bin/SocialBoxCLI
chmod 644 /var/jb/Library/LaunchDaemons/com.socialbox.helper.plist
# Running copies keep the previous binaries mapped; launchd restarts the drain service.
killall -TERM socialbox-drain-service SocialBox 2>/dev/null || true
echo INSTALL_COPIED

# Per-container payload store: same volume as the app data containers so
# switching is rename-based; root-only so inactive containers stay private.
mkdir -p /private/var/mobile/Library/SocialBox/Store
chown root:wheel /private/var/mobile/Library/SocialBox/Store
chmod 700 /private/var/mobile/Library/SocialBox/Store
echo STORE_READY

# Client-side keychain (IG/FB) plus developer location inject. Do not ship
# securityd/cfprefsd/containermanagerd injects from this script.
INJECT_DST="/var/jb/Library/MobileSubstrate/DynamicLibraries"
TWEAK_DST="/var/jb/usr/lib/TweakInject"
removed=0
for dir in "$INJECT_DST" "$TWEAK_DST"; do
  for f in "$dir"/SocialBox*.dylib "$dir"/SocialBox*.plist; do
    [ -e "$f" ] || continue
    rm -f "$f"
    removed=1
    echo "REMOVE_INJECT:$f"
  done
done
mkdir -p "$INJECT_DST" "$TWEAK_DST"
for name in SocialBoxAppKeychain SocialBoxLocation; do
  src_d="$STAGE/Library/MobileSubstrate/DynamicLibraries/${name}.dylib"
  src_p="$STAGE/Library/MobileSubstrate/DynamicLibraries/${name}.plist"
  if [ -f "$src_d" ] && [ -f "$src_p" ]; then
    cp -f "$src_d" "$INJECT_DST/${name}.dylib"
    cp -f "$src_p" "$INJECT_DST/${name}.plist"
    cp -f "$src_d" "$TWEAK_DST/${name}.dylib"
    cp -f "$src_p" "$TWEAK_DST/${name}.plist"
    chmod 755 "$INJECT_DST/${name}.dylib" "$TWEAK_DST/${name}.dylib"
    chmod 644 "$INJECT_DST/${name}.plist" "$TWEAK_DST/${name}.plist"
    echo "INJECT_INSTALLED:$name"
  fi
done
if [ "$removed" = 1 ]; then
  launchctl kickstart -k system/com.apple.cfprefsd.xpc.daemon 2>/dev/null || true
  launchctl kickstart -k system/com.apple.containermanagerd 2>/dev/null || true
  sleep 3
  echo DAEMONS_RESTARTED
fi

if launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.socialbox.helper.plist 2>/tmp/sb_boot.err; then
  echo BOOTSTRAP_OK
else
  echo BOOTSTRAP_FAILED
  cat /tmp/sb_boot.err 2>/dev/null || true
fi
sleep 1
echo '--- launchctl print ---'
launchctl print system/com.socialbox.helper 2>&1 | head -30 || true

echo '--- installed digests ---'
for f in \
  /var/jb/Applications/SocialBox.app/SocialBox \
  /var/jb/usr/libexec/SocialBoxHelper \
  /var/jb/usr/local/bin/SocialBoxCLI \
  /var/jb/usr/libexec/socialbox-drain-service \
  /var/jb/Library/LaunchDaemons/com.socialbox.helper.plist
do
  if [ -f "$f" ]; then
    sz=$(stat -c%s "$f")
    sh=$(sha256sum "$f" | cut -d' ' -f1)
    echo "PIN|$f|$sz|$sh"
  else
    echo "MISSING|$f"
  fi
done

echo END_INSTALL
