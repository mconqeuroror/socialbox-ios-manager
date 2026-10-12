#import "LBXContainerMutationCoordinator.h"
#import "LBXContainerPendingMutation.h"
#import "LBXContainerConfiguration.h"
#import "LBXContainerClient.h"
#import "LBXContainerIPC.h"
#import "../Authorization/LBXLicenseClient.h"
#import "../Authorization/LBXLicenseIPC.h"

static NSDictionary *CopyJSON(id value,NSUInteger maximum) {
    @try {
        if(![value isKindOfClass:NSDictionary.class]||![NSJSONSerialization isValidJSONObject:value])return nil;
        NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        return data.length&&data.length<=maximum?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    } @catch(NSException *exception) {(void)exception;return nil;}
}
static LBXContainerConfiguration *Configuration(id value) {
    LBXContainerConfiguration *c=[LBXContainerConfiguration fromDictionary:value error:nil];
    return c&&[c.privateDictionary isEqual:value]?c:nil;
}
static NSString *FailureResult(NSString *result) {
    if([result isEqual:@"authorization_required"])return result;
    if([result isEqual:@"conflict"]||[result isEqual:@"invalid_request"])return result;
    return @"unconfirmed";
}
#if LBX_CONTAINER_MUTATION_TESTING
static LBXMutationLicenseSender TestLicenseSender;
static LBXMutationContainerSender TestContainerSender;
#endif

@interface LBXContainerMutationCoordinator ()
- (instancetype)initPrivateWithJournal:(LBXContainerPendingMutation *)journal;
@end
@implementation LBXContainerMutationCoordinator {
    LBXContainerPendingMutation *_journal;
    dispatch_queue_t _queue;
    BOOL _busy;
    uint64_t _generation,_step;
    // An exact root proof precedes clear. If local publication is uncertain,
    // retain its candidate in this process until a fresh exact read reconciles.
    // A verified empty state after restart may already reflect that safe clear.
    NSDictionary *_cleanupMutation;
}
- (instancetype)initPrivateWithJournal:(LBXContainerPendingMutation *)journal {
    if((self=[super init])){_journal=journal;_queue=dispatch_queue_create("com.socialbox.saved-setup-coordinator",DISPATCH_QUEUE_SERIAL);}return self;
}
+ (instancetype)openWithCreate:(BOOL)create error:(NSError **)error {
    LBXContainerPendingMutation *journal=[LBXContainerPendingMutation openWithCreate:create error:error];
    return journal?[[self alloc] initPrivateWithJournal:journal]:nil;
}
- (NSString *)description {return @"<LBXContainerMutationCoordinator: saved setup metadata; runtimeAccepted=false>";}
- (NSString *)debugDescription {return self.description;}
- (NSDictionary *)pendingMutation:(NSError **)error {
    NSError *readError=nil;NSDictionary *pending=[_journal pendingMutation:&readError];if(error)*error=readError;
    @synchronized(self){
        // A later verified nonempty slot supersedes local cleanup memory. Old
        // callbacks must never resurrect it after that later slot is cleared.
        if(!readError&&pending&&_cleanupMutation&&![pending isEqual:_cleanupMutation])_cleanupMutation=nil;
        return pending?:_cleanupMutation;
    }
}
- (void)deliver:(NSString *)result configuration:(NSDictionary *)configuration entries:(NSArray *)entries next:(NSString *)next
          completion:(void (^)(NSDictionary *))completion {
    NSError *error=nil;NSDictionary *pending=[self pendingMutation:&error];
    // Unsafe storage is distinct from verified empty; conservatively block new
    // mutations even when its private candidate cannot currently be read.
    NSDictionary *reply=CopyJSON(@{@"result":error?@"journal_unavailable":result,
        @"configuration":configuration?:NSNull.null,@"entries":entries?:@[],@"next":next?:@"",
        @"pending":@((BOOL)(error||pending!=nil)),@"runtimeAccepted":@NO},65536);
    dispatch_async(dispatch_get_main_queue(),^{completion(reply);});
}
- (void)finish:(NSString *)result configuration:(NSDictionary *)configuration entries:(NSArray *)entries next:(NSString *)next
         generation:(uint64_t)generation completion:(void (^)(NSDictionary *))completion {
    if(!_busy||generation!=_generation)return;
    _busy=NO;_step++;[self deliver:result configuration:configuration entries:entries next:next completion:completion];
}
- (BOOL)start:(void (^)(NSDictionary *))completion generation:(uint64_t *)generation {
    if(_busy){[self deliver:@"busy" configuration:nil entries:nil next:nil completion:completion];return NO;}
    NSError *error=nil;[self pendingMutation:&error];
    if(error){[self deliver:@"journal_unavailable" configuration:nil entries:nil next:nil completion:completion];return NO;}
    _busy=YES;*generation=++_generation;return YES;
}
- (BOOL)pendingIsCurrent:(NSDictionary *)slot {
    NSError *error=nil;NSDictionary *current=[self pendingMutation:&error];return !error&&[current isEqual:slot];
}
- (void)validateGeneration:(uint64_t)generation completion:(void (^)(NSString *))completion {
    NSDictionary *request=LBXLicenseIPCRequest(@"validate",nil);uint64_t step=++_step;
    void (^callback)(NSDictionary *)=^(NSDictionary *raw){
        NSDictionary *reply=CopyJSON(raw,2048);
        dispatch_async(self->_queue,^{
            if(!self->_busy||self->_generation!=generation||self->_step!=step)return;
            // The fixed client owns transport nonce/peer authentication. This
            // local check additionally enforces its returned typed semantics;
            // it does not create a second pairing or server authority.
            NSMutableDictionary *shape=[request mutableCopy];shape[@"requestID"]=reply[@"requestID"]?:@"";
            if(!LBXLicenseIPCValidateReply(reply,shape,LBXLicenseIPCClock())){completion(@"unconfirmed");return;}
            NSString *result=reply[@"result"];
            completion([result isEqual:@"active"]?@"active":
                [result isEqual:@"service_unavailable"]?@"unconfirmed":@"authorization_required");
        });
    };
#if LBX_CONTAINER_MUTATION_TESTING
    LBXMutationLicenseSender sender;@synchronized(self.class){sender=[TestLicenseSender copy];}
    if(sender){sender(@"validate",nil,callback);return;}
#endif
    LBXSendLicenseRequest(@"validate",nil,callback);
}
- (void)sendOperation:(NSString *)operation arguments:(NSDictionary *)arguments generation:(uint64_t)generation
             completion:(void (^)(NSDictionary *))completion {
    NSDictionary *request=LBXContainerIPCRequest(operation,arguments);uint64_t step=++_step;
    if(!request){completion(nil);return;}
    void (^callback)(NSDictionary *)=^(NSDictionary *raw){
        NSDictionary *reply=CopyJSON(raw,65536);
        dispatch_async(self->_queue,^{
            if(!self->_busy||self->_generation!=generation||self->_step!=step)return;
            NSMutableDictionary *shape=[request mutableCopy];shape[@"requestID"]=reply[@"requestID"]?:@"";
            completion(LBXContainerIPCValidateReply(reply,shape,LBXContainerIPCClock())?reply:nil);
        });
    };
#if LBX_CONTAINER_MUTATION_TESTING
    LBXMutationContainerSender sender;@synchronized(self.class){sender=[TestContainerSender copy];}
    if(sender){sender(operation,arguments,callback);return;}
#endif
    LBXSendContainerRequest(operation,arguments,callback);
}
- (void)validateWithCompletion:(void (^)(NSDictionary *))completion {
    dispatch_async(_queue,^{uint64_t generation;if(![self start:completion generation:&generation])return;
        [self validateGeneration:generation completion:^(NSString *result){[self finish:result configuration:nil entries:nil next:nil generation:generation completion:completion];}];});
}
- (void)queryOperation:(NSString *)operation arguments:(NSDictionary *)arguments completion:(void (^)(NSDictionary *))completion {
    NSDictionary *snapshot=CopyJSON(arguments,16384);
    dispatch_async(_queue,^{uint64_t generation;if(![self start:completion generation:&generation])return;
        if(!snapshot||!LBXContainerIPCRequest(operation,snapshot)){[self finish:@"invalid_request" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
        [self validateGeneration:generation completion:^(NSString *validation){
            if(![validation isEqual:@"active"]){[self finish:validation configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
            [self sendOperation:operation arguments:snapshot generation:generation completion:^(NSDictionary *reply){
                NSString *result=reply[@"result"];
                BOOL accepted=([operation isEqual:@"list"]&&[result isEqual:@"listed"])||([operation isEqual:@"read"]&&[result isEqual:@"record"]);
                [self finish:accepted?result:FailureResult(result) configuration:accepted&&reply[@"configuration"]!=NSNull.null?reply[@"configuration"]:nil
                    entries:accepted?reply[@"entries"]:nil next:accepted?reply[@"next"]:nil generation:generation completion:completion];
            }];
        }];});
}
- (void)listAfter:(NSString *)after completion:(void (^)(NSDictionary *))completion {
    [self queryOperation:@"list" arguments:@{@"after":[after isKindOfClass:NSString.class]?[after copy]:NSNull.null} completion:completion];
}
- (void)readConfigurationWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *))completion {
    [self queryOperation:@"read" arguments:@{@"identifier":[identifier isKindOfClass:NSString.class]?[identifier copy]:NSNull.null} completion:completion];
}
- (void)confirmMutation:(NSDictionary *)slot generation:(uint64_t)generation completion:(void (^)(NSDictionary *))completion {
    NSError *error=nil;NSDictionary *disk=[_journal pendingMutation:&error];BOOL cleared=NO;
    if(!error&&disk&&![disk isEqual:slot]){[self finish:@"conflict" configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
    if(!error&&[disk isEqual:slot])cleared=[_journal clearConfirmedMutation:slot error:&error];
    else if(!error&&!disk){@synchronized(self){cleared=[_cleanupMutation isEqual:slot];}}
    if(cleared){@synchronized(self){_cleanupMutation=nil;}[self finish:@"saved" configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
    NSError *currentError=nil;NSDictionary *current=[_journal pendingMutation:&currentError];
    if(!currentError&&current&&![current isEqual:slot]){
        @synchronized(self){if([_cleanupMutation isEqual:slot])_cleanupMutation=nil;}
        [self finish:@"conflict" configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;
    }
    @synchronized(self){_cleanupMutation=slot;}
    [self finish:error?@"journal_unavailable":@"unconfirmed" configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];
}
- (void)sendValidatedMutation:(NSDictionary *)slot generation:(uint64_t)generation completion:(void (^)(NSDictionary *))completion {
    if(![self pendingIsCurrent:slot]){[self finish:@"conflict" configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
    NSError *error=nil;NSDictionary *attempt=[_journal beginAttemptForMutation:slot error:&error];
    if(!attempt){[self finish:error.code==2?@"conflict":@"journal_unavailable" configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
    NSString *operation=attempt[@"operation"];NSMutableDictionary *arguments=[@{@"configuration":attempt[@"configuration"]} mutableCopy];
    if([operation isEqual:@"update"])arguments[@"expected"]=attempt[@"expected"];
    [self sendOperation:operation arguments:arguments generation:generation completion:^(NSDictionary *reply){
        if(![self pendingIsCurrent:attempt]){[self finish:@"conflict" configuration:attempt[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
        if([reply[@"result"] isEqual:@"saved"]){[self confirmMutation:attempt generation:generation completion:completion];return;}
        [self finish:FailureResult(reply[@"result"]) configuration:attempt[@"configuration"] entries:nil next:nil generation:generation completion:completion];
    }];
}
- (void)sendMutation:(NSDictionary *)slot generation:(uint64_t)generation completion:(void (^)(NSDictionary *))completion {
    if(![self pendingIsCurrent:slot]){[self finish:@"conflict" configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
    [self validateGeneration:generation completion:^(NSString *validation){
        if(![validation isEqual:@"active"]){[self finish:validation configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
        [self sendValidatedMutation:slot generation:generation completion:completion];
    }];
}
- (void)stageAndSend:(LBXContainerConfiguration *)candidate replacing:(LBXContainerConfiguration *)expected
          generation:(uint64_t)generation completion:(void (^)(NSDictionary *))completion {
    NSError *error=nil;NSDictionary *slot=[_journal stageConfiguration:candidate replacing:expected error:&error];
    if(!slot){[self finish:error.code==2?@"conflict":@"journal_unavailable" configuration:candidate.privateDictionary entries:nil next:nil generation:generation completion:completion];return;}
    [self sendMutation:slot generation:generation completion:completion];
}
- (void)beginCreationWithChoices:(NSDictionary *)choices completion:(void (^)(NSDictionary *))completion {
    NSDictionary *snapshot=CopyJSON(choices,16384);
    dispatch_async(_queue,^{uint64_t generation;if(![self start:completion generation:&generation])return;
        NSError *error=nil;NSDictionary *pending=[self pendingMutation:&error];
        if(error||pending){[self finish:error?@"journal_unavailable":@"conflict" configuration:pending[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
        if(!snapshot||![snapshot[@"proxyReference"] isEqual:@""]||!LBXContainerIPCRequest(@"prepare",@{@"choices":snapshot})){[self finish:@"invalid_request" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
        [self validateGeneration:generation completion:^(NSString *validation){
            if(![validation isEqual:@"active"]){[self finish:validation configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
            [self sendOperation:@"prepare" arguments:@{@"choices":snapshot} generation:generation completion:^(NSDictionary *reply){
                LBXContainerConfiguration *candidate=[reply[@"result"] isEqual:@"prepared"]?Configuration(reply[@"configuration"]):nil;
                if(!candidate){[self finish:FailureResult(reply[@"result"]) configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
                [self stageAndSend:candidate replacing:nil generation:generation completion:completion];
            }];
        }];});
}
- (void)beginUpdateOfConfiguration:(LBXContainerConfiguration *)expected name:(NSString *)name applications:(NSArray<NSString *> *)applications
                  manualIdentifiers:(NSDictionary<NSString *,NSString *> *)manualIdentifiers completion:(void (^)(NSDictionary *))completion {
    LBXContainerConfiguration *prior=[expected isKindOfClass:LBXContainerConfiguration.class]?Configuration(expected.privateDictionary):nil;
    // Construct synchronously while caller inputs are owned; the model copies
    // every retained value, preserving all existing random/manual identifiers.
    LBXContainerConfiguration *candidate=[prior configurationByUpdatingName:name applications:applications manualIdentifiers:manualIdentifiers proxyReference:nil error:nil];
    dispatch_async(_queue,^{uint64_t generation;if(![self start:completion generation:&generation])return;
        NSError *error=nil;NSDictionary *pending=[self pendingMutation:&error];
        if(error||pending){[self finish:error?@"journal_unavailable":@"conflict" configuration:pending[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
        if(!prior||!candidate){[self finish:@"invalid_request" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
        [self validateGeneration:generation completion:^(NSString *validation){
            if(![validation isEqual:@"active"]){[self finish:validation configuration:candidate.privateDictionary entries:nil next:nil generation:generation completion:completion];return;}
            [self stageAndSend:candidate replacing:prior generation:generation completion:completion];
        }];});
}
- (void)reconcile:(BOOL)retry completion:(void (^)(NSDictionary *))completion {
    dispatch_async(_queue,^{uint64_t generation;if(![self start:completion generation:&generation])return;
        NSError *error=nil;NSDictionary *slot=[self pendingMutation:&error];
        if(error||!slot){[self finish:error?@"journal_unavailable":@"no_pending" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
        [self validateGeneration:generation completion:^(NSString *validation){
            if(![validation isEqual:@"active"]){[self finish:validation configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
            if(![self pendingIsCurrent:slot]){[self finish:@"conflict" configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
            [self sendOperation:@"read" arguments:@{@"identifier":slot[@"configuration"][@"identifier"]} generation:generation completion:^(NSDictionary *reply){
                if(![self pendingIsCurrent:slot]){[self finish:@"conflict" configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
                NSString *result=reply[@"result"];NSDictionary *record=reply[@"configuration"];
                if([result isEqual:@"record"]&&[record isEqual:slot[@"configuration"]]){[self confirmMutation:slot generation:generation completion:completion];return;}
                BOOL safeRetry=([slot[@"operation"] isEqual:@"create"]&&[result isEqual:@"missing"])||
                    ([slot[@"operation"] isEqual:@"update"]&&[result isEqual:@"record"]&&[record isEqual:slot[@"expected"]]);
                if(safeRetry&&retry){[self sendMutation:slot generation:generation completion:completion];return;}
                NSString *outcome=safeRetry?@"retry_required":[@[@"record",@"missing"] containsObject:result?:@""]?@"conflict":FailureResult(result);
                [self finish:outcome configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];
            }];
        }];});
}
- (void)reconcilePendingWithCompletion:(void (^)(NSDictionary *))completion {[self reconcile:NO completion:completion];}
- (void)retryPendingWithCompletion:(void (^)(NSDictionary *))completion {[self reconcile:YES completion:completion];}
- (NSDictionary *)safeStatus {NSError *error=nil;NSDictionary *slot=[self pendingMutation:&error];return @{@"available":@((BOOL)!error),@"hasPending":@((BOOL)(error||slot!=nil)),@"runtimeAccepted":@NO};}
#if LBX_CONTAINER_MUTATION_TESTING
+ (void)testUseLicenseSender:(LBXMutationLicenseSender)licenseSender containerSender:(LBXMutationContainerSender)containerSender {
    @synchronized(self){TestLicenseSender=[licenseSender copy];TestContainerSender=[containerSender copy];}
}
- (void)testStopJournalAfterBoundary:(NSString *)boundary {[_journal testStopAfterBoundary:boundary];}
#endif
@end
