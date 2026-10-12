#pragma once
#import <Foundation/Foundation.h>

#if RBX_PACKAGE_ROOTLESS
// Theos/libroot resolves the active rootless bootstrap, including relocated
// roots. Rootful builds never select a stale /var/jb installation.
#include <rootless.h>
#endif

static inline NSString *RBXInstalledPath(NSString *rootfulPath) {
#if RBX_PACKAGE_ROOTLESS
    return ROOT_PATH_NS_VAR(rootfulPath);
#else
    return rootfulPath;
#endif
}

static inline NSString *RBXInstalledScheme(void) {
#if RBX_PACKAGE_ROOTLESS
    return @"rootless";
#else
    return @"rootful";
#endif
}
