#ifndef LBX_INJECT_COMMON_H
#define LBX_INJECT_COMMON_H

#import <Foundation/Foundation.h>
#include <stdbool.h>

// Shared, IG/FB-only support code for the per-daemon SocialBox injects
// (securityd / cfprefsd / containermanagerd). This layer carries zero product
// literals beyond the sanctioned SocialBox keychain token and control paths,
// which are imported from the single source of truth LBXSocialBoxProduct.h so
// the injects, helper, launchd and entitlements stay in lock-step.
//
// PINNED ABI POLICY
// -----------------
// Every daemon hook is installed by SYMBOL / SELECTOR name against the running
// image at load time; no instruction offsets or private struct layouts are
// baked into these dylibs. The "pin" is therefore:
//   (1) the C/ObjC signature of each hooked entry point (declared explicitly
//       in each inject translation unit), and
//   (2) an OS-version guard (LBXInjectOSMajorIsPinned) that refuses to install
//       any hook outside the validated Darwin major for this device image.
// If a required symbol is absent, or the OS major is not the pinned one, the
// inject installs NOTHING and the daemon runs stock (fail-closed). This is the
// sanctioned way to touch securityd/cfprefsd: pin explicitly, never blind-patch.

NS_ASSUME_NONNULL_BEGIN

// Official Instagram and Facebook only. Never Twitter / any other app.
extern NSString *const LBXInjectInstagramBundleID;   // com.burbn.instagram
extern NSString *const LBXInjectFacebookBundleID;    // com.facebook.Facebook

// YES only for the two supported official bundle identifiers.
bool LBXInjectIsSupportedBundleID(NSString *_Nullable bundleID);

// Maps Instagram / Facebook and their official extensions to the host app
// bundle used for container selection. Returns nil for every other process.
NSString *_Nullable LBXInjectHostBundleID(NSString *_Nullable bundleID);

// Device image ABI pin. The recovered device is Darwin 22.x (iOS 16.x) on
// iPhone10,6 / T8015. Hooks install only when the running kernel's Darwin major
// equals the pinned value. Returns false on any other image (fail-closed).
bool LBXInjectOSMajorIsPinned(void);

// Reads /private/var/tmp/socialbox_containers/<bundleID>.plist (written by the
// SocialBox helper via writeRuntimeSelection:forBundleID:) and returns the
// numeric activeContainer, or <= 0 when no valid selection exists.
long long LBXInjectActiveContainerForBundleID(NSString *bundleID);

// Builds the sanctioned keychain access group literal for a container:
//   %.s_o_c_i_a_l_b_o_x.<CID>
// The leading "%." is the wildcard team-id prefix the SocialBox stack addresses
// through its wildcard keychain-access-groups entitlement.
NSString *_Nullable LBXInjectAccessGroupForContainer(long long containerID);

// Per-CID profile root for sandbox/preferences redirection, e.g.
//   /var/jb/var/mobile/Library/___SocialBox_Containers/<CID>
NSString *_Nullable LBXInjectProfileRootForContainer(long long containerID);

// Classifies a caller: maps a known Instagram or Facebook keychain identity
// token (access group, service or application-identifier value) to one of the
// supported bundle identifiers. Returns nil for anything unrecognised so stock
// behaviour is preserved for every other process on the device.
NSString *_Nullable LBXInjectBundleIDForKeychainIdentity(NSString *_Nullable identity);

// Lightweight, redaction-safe trace to the unified log subsystem
// com.socialbox.inject. No account bytes, no product-legacy literals.
void LBXInjectLog(const char *category, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

NS_ASSUME_NONNULL_END

#endif /* LBX_INJECT_COMMON_H */
