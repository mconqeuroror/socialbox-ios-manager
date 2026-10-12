#import <Foundation/Foundation.h>
#import "../Switching/LBXManagedApplications.h"
NS_ASSUME_NONNULL_BEGIN
#define LBX_DRAIN_SERVICE "com.socialbox.processdrain"
FOUNDATION_EXPORT double LBXDrainClock(void);
FOUNDATION_EXPORT BOOL LBXValidateDrainRequest(id request, double now);
FOUNDATION_EXPORT BOOL LBXValidateDrainReply(id reply, NSDictionary *request, double now);
FOUNDATION_EXPORT NSDictionary *LBXDrainFailure(NSDictionary *request, NSString *reason);
// Authenticated, read-only service round trip. Never a drain or launch receipt.
FOUNDATION_EXPORT NSDictionary * _Nullable LBXServiceCheckReply(id request, double now);
FOUNDATION_EXPORT BOOL LBXValidateServiceCheckReply(id reply, NSDictionary *request, double now);
NS_ASSUME_NONNULL_END
