#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Structural identities of SocialBox control files for official Instagram
// and Facebook. Records device/inode/mode only. Never reads plist bytes, never
// writes selection, and is not a fence or isolation claim.
@interface LBXNativeControlLayout : NSObject
+ (nullable instancetype)observeOfficialFamily:(NSError **)error;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#if LBX_NATIVE_CONTROL_LAYOUT_TESTING
@interface LBXNativeControlLayout (Testing)
+ (nullable instancetype)testObserveContainers:(NSString *)containers
                                 runtimePlists:(NSString *)runtimePlists
                                         error:(NSError **)error;
@end
#endif
NS_ASSUME_NONNULL_END
