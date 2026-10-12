#import <Foundation/Foundation.h>
@class LBXNativeApplicationGate;
NS_ASSUME_NONNULL_BEGIN

// Holds official Instagram and Facebook execution gates together. Close always
// attempts both. Restore requires both drains and restores Facebook first so a
// Facebook failure leaves Instagram closed. This is not isolation.
@interface LBXNativeFamilyApplicationGate : NSObject
+ (nullable instancetype)gateWithInstagram:(LBXNativeApplicationGate *)instagram
                                  facebook:(LBXNativeApplicationGate *)facebook
                                     error:(NSError **)error;
- (BOOL)closeAndDrainBeforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)restoreExecutionBeforeDeadline:(double)deadline
                       authorization:(BOOL (^)(void))authorization error:(NSError **)error;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
