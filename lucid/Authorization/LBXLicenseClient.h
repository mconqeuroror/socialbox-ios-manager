#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Completion is one-shot; rejected input may finish inline. UI callers dispatch
// to the main queue and must not turn this assessment into engine admission.
FOUNDATION_EXPORT void LBXSendLicenseRequest(NSString *operation, NSString * _Nullable key, void (^completion)(NSDictionary *));
NS_ASSUME_NONNULL_END
