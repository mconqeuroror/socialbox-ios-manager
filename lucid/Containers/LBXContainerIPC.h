#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Private authenticated app/service payloads, not public diagnostics or grants.
// Full configuration payloads contain user identity choices; never log/export
// requests or replies. Only the service owns paths, authorization and storage.
// Requests are bounded to 16 KiB; replies to 64 KiB for forty-item Unicode pages.
FOUNDATION_EXPORT double LBXContainerIPCClock(void);
FOUNDATION_EXPORT NSDictionary * _Nullable LBXContainerIPCRequest(NSString *operation, NSDictionary *arguments);
FOUNDATION_EXPORT BOOL LBXContainerIPCValidateRequest(id request, double now);
FOUNDATION_EXPORT NSDictionary *LBXContainerIPCReply(NSDictionary *request, NSString *result,
    NSDictionary * _Nullable configuration, NSArray<NSDictionary *> * _Nullable entries, NSString * _Nullable next);
FOUNDATION_EXPORT NSDictionary *LBXContainerIPCFailure(NSDictionary *request, NSString *result);
FOUNDATION_EXPORT BOOL LBXContainerIPCValidateReply(id reply, NSDictionary *request, double now);
// Exact, bounded list projection: UUID/revision/name/requested membership only.
FOUNDATION_EXPORT NSDictionary * _Nullable LBXContainerIPCListEntry(NSDictionary *configuration);
NS_ASSUME_NONNULL_END
