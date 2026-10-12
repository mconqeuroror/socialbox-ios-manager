#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Read-only pin of the original manager binary. This is not interposition:
// required switch selectors stay documented, never swapped, and the original
// worker is never invoked. A matching digest does not mean the installed
// switch is connected.
@interface LBXNativeInstalledManagerPin : NSObject
+ (nullable instancetype)observeOriginalManager:(NSError **)error;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#if LBX_NATIVE_INSTALLED_MANAGER_PIN_TESTING
@interface LBXNativeInstalledManagerPin (Testing)
+ (nullable instancetype)testObservePath:(NSString *)path
                         expectedSHA256:(NSString *)hex
                           expectedSize:(unsigned long long)size
                                  error:(NSError **)error;
@end
#endif
NS_ASSUME_NONNULL_END
