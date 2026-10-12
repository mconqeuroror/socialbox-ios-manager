#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Private setup choices/result only. No runtime grant or recovered callbacks.
// The controller retains the accepted prepare document across uncertain create
// replies and resends that exact document with a new envelope, never a new UUID.
FOUNDATION_EXPORT void LBXSendContainerRequest(NSString *operation,NSDictionary *arguments,
                                              void (^completion)(NSDictionary *));
NS_ASSUME_NONNULL_END
