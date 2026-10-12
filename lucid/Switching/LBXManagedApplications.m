#import "LBXManagedApplications.h"

NSDictionary<NSString *, NSString *> *LBXManagedApplications(void) {
    static NSDictionary *apps; static dispatch_once_t once;
    dispatch_once(&once, ^{
        apps = @{
#define LBX_APPLICATION(identifier, name) @identifier : @name,
#include "LBXManagedApplications.def"
#undef LBX_APPLICATION
        };
    });
    return apps;
}
BOOL LBXDrainSupportedApplication(NSString *bundleID) {
    return [bundleID isKindOfClass:NSString.class] && LBXManagedApplications()[bundleID] != nil;
}
