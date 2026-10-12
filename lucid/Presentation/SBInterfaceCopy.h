#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Authored interface copy only. Backend captions and user values belong to
// their explicit compatibility/display roles, never this semantic catalog.
FOUNDATION_EXPORT NSString *SBUIText(NSString *key);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *SBInterfaceTextCatalog(void);
FOUNDATION_EXPORT BOOL SBUIHasText(NSString *key);
// Typed formatting keeps compiler validation of the exact integer arguments.
FOUNDATION_EXPORT NSString *SBUIContainerCount(NSUInteger shown, NSUInteger total);
FOUNDATION_EXPORT NSString *SBUIAppCount(NSUInteger count);
NS_ASSUME_NONNULL_END
