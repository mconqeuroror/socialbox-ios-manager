#pragma once
// Build-time endpoints for the source-owned license owner. Acceptance builds
// override these before including this header; no runtime endpoint is accepted.
#ifndef LBX_LICENSE_SERVICE_NAME
#define LBX_LICENSE_SERVICE_NAME "com.socialbox.licensing"
#endif
#ifndef LBX_LICENSE_SERVICE_PATH
#define LBX_LICENSE_SERVICE_PATH "/var/jb/usr/libexec/socialbox-license-owner"
#endif
#ifndef LBX_LICENSE_VAULT_PATH
#define LBX_LICENSE_VAULT_PATH "/var/jb/var/lib/socialbox-license-pairing"
#endif
#ifndef LBX_LICENSE_INSTALLATION_PATH
#define LBX_LICENSE_INSTALLATION_PATH "/var/jb/var/lib/socialbox-installation"
#endif
#ifndef LBX_LICENSE_INSTALLER_PATH
#define LBX_LICENSE_INSTALLER_PATH "/var/jb/usr/libexec/socialbox-prepare-installation"
#endif
#ifndef LBX_LICENSE_CLIENT_PATH
#define LBX_LICENSE_CLIENT_PATH "/var/jb/Applications/SocialBox.app/SocialBox"
#endif
#ifndef LBX_LICENSE_CLIENT_SHA256
#define LBX_LICENSE_CLIENT_SHA256 "4fff45cdabf2e5b7075e4279f5a87dea9add383c7e7049038f57afb4cbb09647"
#endif
#ifndef LBX_LICENSE_CLIENT_SIZE
#define LBX_LICENSE_CLIENT_SIZE 271424
#endif
