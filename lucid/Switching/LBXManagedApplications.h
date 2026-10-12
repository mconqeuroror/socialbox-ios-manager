#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Exact main IDs only. Extensions are resolved from the registered app bundle;
// a prefix, supplied executable/path or arbitrary installed app is never enough.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *LBXManagedApplications(void);
FOUNDATION_EXPORT BOOL LBXDrainSupportedApplication(NSString * _Nullable bundleID);
NS_ASSUME_NONNULL_END
