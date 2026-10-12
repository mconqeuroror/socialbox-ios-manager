#pragma once
// Product identities for the SocialBox source rebuild. Published digests pin
// freshly compiled manager/helper/cli artifacts. Zero size/digest would admit
// path-only peers (no recovered prebuilt hash match).

#define LBX_SOCIALBOX_MANAGER_PATH "/var/jb/Applications/SocialBox.app/SocialBox"
#define LBX_SOCIALBOX_HELPER_PATH "/var/jb/usr/libexec/SocialBoxHelper"
#define LBX_SOCIALBOX_CLI_PATH "/var/jb/usr/local/bin/SocialBoxCLI"
#define LBX_SOCIALBOX_CONTROL_CONTAINERS "/var/jb/var/mobile/Library/SocialBox/Containers"
#define LBX_SOCIALBOX_CONTROL_RUNTIME "/private/var/tmp/socialbox_containers"
#define LBX_SOCIALBOX_PROFILE_STORE "___SocialBox_Containers"
#define LBX_SOCIALBOX_BUNDLE_ID "com.socialbox.app"
#define LBX_SOCIALBOX_HELPER_MACH "com.socialbox.helper.xpc"
#define LBX_SOCIALBOX_HELPER_LABEL "com.socialbox.helper"
#define LBX_SOCIALBOX_KEYCHAIN_TOKEN "s_o_c_i_a_l_b_o_x"

// Digests from source rebuilds on 2026-10-12 (arm64+arm64e rootless, dark manager).
// Helper digest pins the on-device installed bytes (ldid -S can change signature
// size). Manager/CLI peer pins are what helper admission enforces; helper self-sha
// is inert.
#ifndef LBX_SOCIALBOX_MANAGER_SIZE
#define LBX_SOCIALBOX_MANAGER_SIZE 576352
#endif
#ifndef LBX_SOCIALBOX_MANAGER_SHA256
#define LBX_SOCIALBOX_MANAGER_SHA256 "3a1126e7a924594c928dd061565ba6f56f695b40225aa28d0a79cb952afd6c0e"
#endif
#ifndef LBX_SOCIALBOX_HELPER_SIZE
#define LBX_SOCIALBOX_HELPER_SIZE 362464
#endif
#ifndef LBX_SOCIALBOX_HELPER_SHA256
#define LBX_SOCIALBOX_HELPER_SHA256 "c4e50aec65dec0c7aca6b1c89d951c7dccac05e086f73e8691f1a72d04c0a396"
#endif
#ifndef LBX_SOCIALBOX_CLI_SIZE
#define LBX_SOCIALBOX_CLI_SIZE 270096
#endif
#ifndef LBX_SOCIALBOX_CLI_SHA256
#define LBX_SOCIALBOX_CLI_SHA256 "49ed88d60797a21897955abf3617dcf1c916499ba2f8d0d63092fc2162667104"
#endif
