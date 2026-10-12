#import "LBXLicenseOwner.h"
#import "LBXLicenseIPC.h"
#import "LBXLicenseVault.h"
#import "LBXLicenseTransport.h"
#import "LBXLicenseEndpoints.h"
#include <unistd.h>
#include <mach/mach_time.h>
#include <math.h>

// Includes device sleep. A wall-clock rollback must not extend admission.
static NSTimeInterval ContinuousClock(void) {
    static mach_timebase_info_data_t scale;static dispatch_once_t once;
    dispatch_once(&once,^{mach_timebase_info(&scale);});
    return scale.denom ? (double)mach_continuous_time()*(double)scale.numer/(double)scale.denom/1e9 : NAN;
}
static const NSTimeInterval MaximumAdmissionSeconds=60;
static const void *OwnerQueueKey=&OwnerQueueKey;
static NSError *SourceOperationError(NSInteger code) {
    NSArray *messages=@[@"Invalid source operation",@"Reentrant source operation refused",
        @"Source operation deadline elapsed",@"Fresh signed authorization is required",
        @"Source operation failed; its consumer must assess recovery"];
    return [NSError errorWithDomain:@"com.socialbox.source-operation" code:code
        userInfo:@{NSLocalizedDescriptionKey:messages[(NSUInteger)code-1]}];
}

@implementation LBXLicenseOwner {
    LBXLicenseVault *_vault;
    LBXLicenseTransport *_transport;
    dispatch_queue_t _queue;
    LBXLicenseVerifiedCommit *_authorization;
    NSTimeInterval _authorizationWall,_authorizationContinuous,_authorizationDuration;
    BOOL _performingSourceOperation;
    NSTimeInterval _sourceOperationDeadline,_sourceOperationSubmitted;
#if LBX_LICENSE_OWNER_TESTING
    Class _testProtocol;NSData *_testKey;NSString *_testKeyID;
    NSTimeInterval (^_testAuthorizationClock)(BOOL);
#endif
}
- (instancetype)initWithVault:(LBXLicenseVault *)vault {
    if(!vault)return nil;
    if((self=[super init])){
        _vault=vault;_queue=dispatch_queue_create("com.socialbox.license.owner",DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue,OwnerQueueKey,(__bridge void *)self,NULL);
    }return self;
}
- (NSString *)description { return @"<LBXLicenseOwner: private pairing owner>"; }
- (BOOL)usesVault:(LBXLicenseVault *)vault {return vault&&vault==_vault;}
- (NSDictionary *)sourcePairingContextBeforeDeadline:(NSTimeInterval)deadline error:(NSError **)error {
    if(error)*error=nil;
#if !LBX_LICENSE_OWNER_TESTING
    if(getuid()!=0||geteuid()!=0){if(error)*error=SourceOperationError(4);return nil;}
#endif
    if(![self sourceOperationCurrentBeforeDeadline:deadline]){if(error)*error=SourceOperationError(4);return nil;}
    NSDictionary *observed=[_vault pairingContextForSourceOwner:self beforeDeadline:deadline error:error];
    if(!observed)return nil;
    NSMutableDictionary *context=[observed mutableCopy];context[@"formatVersion"]=@1;
    // This is the fixed compiled peer policy, never a caller-selected pin or
    // a claim that this root process is itself the mobile client.
    context[@"client"]=@{@"path":@LBX_LICENSE_CLIENT_PATH,@"sha256":@LBX_LICENSE_CLIENT_SHA256,@"size":@(LBX_LICENSE_CLIENT_SIZE)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:context options:NSJSONWritingSortedKeys error:nil];
    NSDictionary *snapshot=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if(!snapshot||![self sourceOperationCurrentBeforeDeadline:deadline]){if(error)*error=SourceOperationError(4);return nil;}
    return snapshot;
}
- (NSTimeInterval)authorizationClock:(BOOL)continuous {
#if LBX_LICENSE_OWNER_TESTING
    if(_testAuthorizationClock)return _testAuthorizationClock(continuous);
#endif
    return continuous?ContinuousClock():NSDate.date.timeIntervalSince1970;
}
- (void)closeSourceAuthorization { @synchronized(self) { _authorization=nil; } }
- (void)installSourceAuthorization:(LBXLicenseVerifiedCommit *)verified {
    @synchronized(self) {
        _authorization=nil;
        NSTimeInterval wall=[self authorizationClock:NO],continuous=[self authorizationClock:YES];
        NSTimeInterval remaining=verified.expiresAt-wall;
        if(![verified.status isEqual:@"active"]||!isfinite(wall)||wall<=0||!isfinite(continuous)||continuous<0||
           !isfinite(remaining)||remaining<=0||![verified matchesConfiguration:[_vault configuration:nil]])return;
        _authorization=verified;_authorizationWall=wall;_authorizationContinuous=continuous;
        _authorizationDuration=MIN(remaining,MaximumAdmissionSeconds);
    }
}
- (BOOL)sourceAuthorizationCurrent {
    @synchronized(self) {
        if(!_authorization)return NO;
        NSTimeInterval wall=[self authorizationClock:NO],continuous=[self authorizationClock:YES];
        if(!isfinite(wall)||wall<_authorizationWall||wall>=_authorization.expiresAt||
           !isfinite(continuous)||continuous<_authorizationContinuous||
           continuous-_authorizationContinuous>=_authorizationDuration||
           ![_authorization matchesConfiguration:[_vault configuration:nil]]) {
            _authorization=nil;return NO;
        }return YES;
    }
}
- (BOOL)sourceOperationCurrentBeforeDeadline:(NSTimeInterval)deadline {
    if(dispatch_get_specific(OwnerQueueKey)!=(__bridge void *)self||!_performingSourceOperation||
       !isfinite(deadline)||deadline!=_sourceOperationDeadline)return NO;
    NSTimeInterval now=LBXLicenseIPCClock();
    if(!isfinite(now)||now<_sourceOperationSubmitted||now>=deadline||![self sourceAuthorizationCurrent])return NO;
    // The signed-state/vault check can wait on private storage; its time also
    // consumes the original fence. Never extend the bound with a caller value.
    now=LBXLicenseIPCClock();
    return isfinite(now)&&now>=_sourceOperationSubmitted&&now<deadline;
}
- (BOOL)performSourceOperation:(BOOL (^)(NSError **))operation beforeDeadline:(NSTimeInterval)deadline error:(NSError **)error {
    if(error)*error=nil;
    // Also reject a different owner's queue: nested owners could otherwise
    // form a synchronous A -> B -> A cycle even though each queue is serial.
    if(dispatch_get_specific(OwnerQueueKey)) {
        if(error)*error=SourceOperationError(2);return NO;
    }
    NSTimeInterval submitted=LBXLicenseIPCClock();
    if(!operation||!isfinite(deadline)||!isfinite(submitted)||submitted<0||deadline<=submitted||deadline>submitted+25) {
        if(error)*error=SourceOperationError(1);return NO;
    }
    __block BOOL succeeded=NO;__block NSInteger failure=0;__block NSError *handlerError=nil;
    dispatch_sync(_queue,^{
        NSTimeInterval now=LBXLicenseIPCClock();
        if(!isfinite(now)||now<submitted||now>=deadline){failure=3;return;}
        if(![self sourceAuthorizationCurrent]){failure=4;return;}
        self->_sourceOperationDeadline=deadline;self->_sourceOperationSubmitted=submitted;
        self->_performingSourceOperation=YES;
        @try {
            NSError *reported=nil;BOOL performed=operation(&reported);
            // This is result validation, not cancellation or rollback. The
            // trusted effect must perform only its one synchronous bounded step.
            now=LBXLicenseIPCClock();
            if(!isfinite(now)||now<submitted||now>=deadline)failure=3;
            else if(![self sourceAuthorizationCurrent])failure=4;
            else if(!performed){failure=5;if([reported isKindOfClass:NSError.class])handlerError=reported;}
            else succeeded=YES;
            if(!succeeded)[self closeSourceAuthorization];
        } @catch(__unused NSException *exception) {
            [self closeSourceAuthorization];failure=5;
        } @finally { self->_performingSourceOperation=NO;self->_sourceOperationDeadline=0;self->_sourceOperationSubmitted=0; }
    });
    if(!succeeded&&error)*error=handlerError?:SourceOperationError(failure?:5);
    return succeeded;
}
- (void)handleRequest:(NSDictionary *)request completion:(void (^)(NSDictionary *))completion {
    if(!completion)return;
    // A synchronous effect cannot enqueue a license mutation behind itself or
    // wait for that mutation. It must return before any new owner work starts.
    if(dispatch_get_specific(OwnerQueueKey)==(__bridge void *)self&&_performingSourceOperation) {
        completion(LBXLicenseIPCReply(@{},@"invalid_request",NO));return;
    }
    // JSON inputs are immutable at the service boundary; take a deep immutable
    // snapshot as well so mutable in-process callers cannot race the queue.
    NSData *data=[NSJSONSerialization isValidJSONObject:request]?[NSJSONSerialization dataWithJSONObject:request options:0 error:nil]:nil;
    id parsed=data.length<=4096&&data.length?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    NSDictionary *snapshot=[parsed isKindOfClass:NSDictionary.class]?parsed:@{};
    dispatch_async(_queue,^{
        void (^finish)(NSString *)=^(NSString *result){completion(LBXLicenseIPCReply(snapshot,result,[self->_vault.safeStatus[@"paired"] boolValue]));};
        if(!LBXLicenseIPCValidateRequest(snapshot,LBXLicenseIPCClock())){finish(@"invalid_request");return;}
        NSDictionary *current=[self->_vault configuration:nil];
        if(!current){[self closeSourceAuthorization];finish(@"storage_unavailable");return;}
        if([snapshot[@"operation"] isEqual:@"status"]){finish(self->_transport?@"busy":@"unchecked");return;}
        if(self->_transport){finish(@"busy");return;}
        BOOL paired=[current[@"deviceId"] length]>0;
        BOOL activate=[snapshot[@"operation"] isEqual:@"activate"];
        if(activate&&paired&&![snapshot[@"key"] isEqual:current[@"key"]]){finish(@"paired_key_mismatch");return;}
        if(!activate&&![current[@"key"] length]){finish(@"activation_required");return;}
        [self closeSourceAuthorization];
        // A retried initial claim uses the same UUID and saved key. Paired
        // installations always validate with their saved bearer.
        NSDictionary *configuration=[self->_vault beginWithKey:activate?snapshot[@"key"]:nil error:nil];
        if(!configuration){finish(@"storage_unavailable");return;}
        BOOL claim=![configuration[@"deviceId"] length];
        NSDictionary *(^provider)(void)=^NSDictionary *{return [self->_vault configuration:nil];};
        void (^received)(NSDictionary *,NSError *)=^(NSDictionary *receipt,NSError *error){
            dispatch_async(self->_queue,^{
                self->_transport=nil;
                // Complete an owned claim even if its UI peer disconnected: a
                // server-side claim may have consumed the one-device slot.
                // The client deadline still prevents accepting a late reply.
                if(!receipt){finish(error.code==409?@"recovery_required":@"verification_failed");return;}
                LBXLicenseVerifiedCommit *verified=[self->_vault commitVerifiedReceipt:receipt expectedConfiguration:configuration error:nil];
                if(!verified){finish(@"verification_failed");return;}
                NSString *result=verified.status;
                if([result isEqual:@"active"] && verified.expiresAt<=NSDate.date.timeIntervalSince1970)result=@"expired";
                // Late replies still preserve their pairing, but never open
                // source admission for an expired operation.
                if([result isEqual:@"active"] && LBXLicenseIPCValidateRequest(snapshot,LBXLicenseIPCClock()))
                    [self installSourceAuthorization:verified];
                finish(result);
            });
        };
#if LBX_LICENSE_OWNER_TESTING
        if(self->_testProtocol)self->_transport=[LBXLicenseTransport testStartWithConfiguration:configuration claim:claim currentConfiguration:provider
            protocolClass:self->_testProtocol publicKeyDER:self->_testKey keyID:self->_testKeyID completion:received error:nil];
        else
#endif
        self->_transport=[LBXLicenseTransport startWithConfiguration:configuration claim:claim currentConfiguration:provider completion:received error:nil];
        if(!self->_transport)finish(@"verification_failed");
    });
}
#if LBX_LICENSE_OWNER_TESTING
- (void)testUseProtocol:(Class)protocol publicKey:(NSData *)key keyID:(NSString *)keyID {
    _testProtocol=protocol;_testKey=[key copy];_testKeyID=[keyID copy];
}
- (void)testUseAuthorizationClock:(NSTimeInterval (^)(BOOL))clock {
    @synchronized(self) { _authorization=nil;_testAuthorizationClock=[clock copy]; }
}
#endif
@end
