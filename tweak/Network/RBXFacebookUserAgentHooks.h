#pragma once
#import <Foundation/Foundation.h>
@class RBXDeviceProfile;

// Producer coverage only; this does not grant app-specific wire readiness.
BOOL RBXInstallFacebookUserAgentHooks(RBXDeviceProfile *profile);
