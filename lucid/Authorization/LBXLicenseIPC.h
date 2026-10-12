#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// No caller-selected origin, identity, bearer, receipt or filesystem path.
FOUNDATION_EXPORT double LBXLicenseIPCClock(void);
FOUNDATION_EXPORT NSDictionary * _Nullable LBXLicenseIPCRequest(NSString *operation, NSString * _Nullable key);
FOUNDATION_EXPORT BOOL LBXLicenseIPCValidateRequest(id request, double now);
FOUNDATION_EXPORT NSDictionary *LBXLicenseIPCReply(NSDictionary *request, NSString *result, BOOL paired);
FOUNDATION_EXPORT BOOL LBXLicenseIPCValidateReply(id reply, NSDictionary *request, double now);
NS_ASSUME_NONNULL_END
