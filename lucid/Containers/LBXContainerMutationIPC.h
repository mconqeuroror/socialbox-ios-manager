#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Private authenticated root pending metadata. Never log/export these payloads.
// This distinct family carries no runtime, proxy, pairing or installation grant.
// Epochs are canonical positive decimal strings bounded by signed 64-bit max;
// stable stage IDs and immutable slot tokens/epochs survive uncertain replies.
// Authored unreserved metadata retirement uses stage-retire with the full
// expected document, then execute-retire/reconcile-retire with the retained
// token/epoch. Only retirement_staged/retirement_retry_required/retired can
// confirm this kind. Existing save verbs/results never execute or confirm it.
// An unsuccessful reply may follow durable effects; preserve exact input and
// freshly reconcile. No application data, numeric CID or account is removed.
FOUNDATION_EXPORT double LBXContainerMutationIPCClock(void);
FOUNDATION_EXPORT NSDictionary * _Nullable LBXContainerMutationIPCRequest(NSString *operation,NSDictionary *arguments);
FOUNDATION_EXPORT BOOL LBXContainerMutationIPCValidateRequest(id request,double now);
FOUNDATION_EXPORT NSDictionary *LBXContainerMutationIPCReply(NSDictionary *request,NSString *result,
    NSDictionary * _Nullable state,NSDictionary * _Nullable configuration,NSArray<NSDictionary *> * _Nullable entries,NSString * _Nullable next);
FOUNDATION_EXPORT NSDictionary *LBXContainerMutationIPCFailure(NSDictionary *request,NSString *result);
FOUNDATION_EXPORT BOOL LBXContainerMutationIPCValidateReply(id reply,NSDictionary *request,double now);
// Strict immutable copies of already projected public state/slots. Unknown
// private fields are rejected, never silently stripped to create authority.
FOUNDATION_EXPORT NSDictionary * _Nullable LBXContainerMutationIPCProjectState(id state);
FOUNDATION_EXPORT NSDictionary * _Nullable LBXContainerMutationIPCProjectSlot(id slot);
NS_ASSUME_NONNULL_END
