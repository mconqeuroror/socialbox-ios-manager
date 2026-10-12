#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// One authenticated typed exchange at the fixed compiled root service. Every
// call gets a fresh wire UUID/24-second deadline. Stable stage ID and slot token
// are caller-retained metadata, never endpoint or authorization overrides.
// Private replies contain saved choices; never log/export them. No test sender.
FOUNDATION_EXPORT void LBXSendContainerMutationRequest(NSString *operation,NSDictionary *arguments,
                                                       void (^completion)(NSDictionary *));
NS_ASSUME_NONNULL_END
