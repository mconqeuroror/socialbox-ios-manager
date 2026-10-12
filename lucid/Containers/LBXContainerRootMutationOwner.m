#import "LBXContainerRootMutationOwner.h"
#import "LBXContainerRootPendingStore.h"
#import "LBXContainerConfiguration.h"
#import "LBXContainerConfigurationStore.h"
#import "LBXContainerMutationIPC.h"
#import "LBXContainerIPC.h"
#import "../Authorization/LBXLicenseOwner.h"
#import "../Authorization/LBXLicenseInstallationEstablishment.h"
#include <unistd.h>
#include <limits.h>
#import <CommonCrypto/CommonDigest.h>

static BOOL RootCaller(void) {
#if LBX_CONTAINER_ROOT_PENDING_TESTING
    return getuid()==geteuid();
#else
    return getuid()==0&&geteuid()==0;
#endif
}
static NSDictionary *CopyJSON(id value) {
    if(![value isKindOfClass:NSDictionary.class]||![NSJSONSerialization isValidJSONObject:value])return nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data.length&&data.length<=16384?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
}
static NSString *Next(NSString *value) {
    return value.longLongValue>0&&value.longLongValue<LLONG_MAX?[NSString stringWithFormat:@"%lld",value.longLongValue+1]:nil;
}
static NSString *Proof(NSDictionary *document) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:nil];
    if(!data.length)return nil;unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,hash);
    NSMutableString *result=[NSMutableString string];for(NSUInteger i=0;i<sizeof(hash);i++)[result appendFormat:@"%02x",hash[i]];return result;
}
static NSString *Failure(NSError *error) {
    if(([error.domain isEqual:@"com.socialbox.source-operation"]&&error.code==4)||
       ([error.domain isEqual:@"com.socialbox.root-pending"]&&error.code==4)||
       ([error.domain isEqual:@"com.socialbox.container-configuration-store"]&&error.code==4))return @"authorization_required";
    if(([error.domain isEqual:@"com.socialbox.root-pending"]&&error.code==2)||
       ([error.domain isEqual:@"com.socialbox.container-configuration-store"]&&error.code==2))return @"conflict";
    // A failure can follow durable attempt/configuration/clear publication.
    // No failure projection reports a saved record or a verified empty slot.
    return @"unconfirmed";
}
@implementation LBXContainerRootMutationOwner {
    LBXLicenseInstallationEstablishment *_installation;LBXLicenseOwner *_owner;LBXContainerConfigurationStore *_configurations;
    LBXContainerRootPendingStore *_pending;NSString *_directory;dispatch_queue_t _queue;
#if LBX_CONTAINER_ROOT_PENDING_TESTING
    NSString *_stop;
#endif
}
- (instancetype)initWithLicenseOwner:(LBXLicenseOwner *)owner configurationStore:(LBXContainerConfigurationStore *)configurations pendingDirectory:(NSString *)directory {
    if(!RootCaller()||![owner isKindOfClass:LBXLicenseOwner.class]||![configurations isKindOfClass:LBXContainerConfigurationStore.class]||
        ![configurations usesLicenseOwner:owner]||![directory isKindOfClass:NSString.class]||!directory.isAbsolutePath)return nil;
    if((self=[super init])){_owner=owner;_configurations=configurations;_directory=[directory copy];
        _queue=dispatch_queue_create("com.socialbox.root-saved-setup-owner",DISPATCH_QUEUE_SERIAL);}return self;
}
- (instancetype)initWithPreparedInstallation:(LBXLicenseInstallationEstablishment *)installation pendingDirectory:(NSString *)directory {
    if(!installation||[installation class]!=NSClassFromString(@"LBXLicenseInstallationEstablishment"))return nil;
    self=[self initWithLicenseOwner:installation.licenseOwner configurationStore:installation.configurationStore pendingDirectory:directory];
    if(self)_installation=installation;return self;
}
- (void)establishPreparedPendingBeforeDeadline:(double)deadline completion:(void (^)(BOOL))completion {
    if(!completion)return;
    // Source owner completion executes on its own serial queue. Enter the same
    // source fence only after moving onto this separate trusted setup queue.
    dispatch_async(_queue,^{
        if(!RootCaller()||!self->_installation){completion(NO);return;}
        BOOL ready=[self->_owner performSourceOperation:^BOOL(NSError **effectError){
            if(!self->_pending)self->_pending=[LBXContainerRootPendingStore openDirectory:self->_directory licenseOwner:self->_owner
                configurationStore:self->_configurations preparedInstallation:self->_installation create:YES beforeDeadline:deadline error:effectError];
            if(!self->_pending)return NO;
            return [self->_pending withLockedStateBeforeDeadline:deadline operation:^BOOL(LBXContainerRootPendingTransaction *transaction,NSError **checkError){
                (void)checkError;return [LBXContainerRootPendingStore projectState:transaction.privateState]!=nil;
            } error:effectError];
        } beforeDeadline:deadline error:nil];
        completion(ready);
    });
}
- (NSString *)description {return @"<LBXContainerRootMutationOwner: private saved metadata; runtimeAccepted=false>";}
- (NSString *)debugDescription {return self.description;}
- (BOOL)readSlot:(NSDictionary *)slot deadline:(double)deadline exact:(BOOL *)exact retry:(BOOL *)retry error:(NSError **)error {
    *exact=NO;*retry=NO;BOOL absent=NO;
    BOOL retire=[slot[@"operation"] isEqual:@"retire"];
    if(retire){
        LBXContainerConfiguration *candidate=[LBXContainerConfiguration fromDictionary:slot[@"configuration"] error:nil];NSError *retirementError=nil;
        if([_configurations retirementCurrentForConfiguration:candidate inCurrentSourceOperationBeforeDeadline:deadline error:&retirementError]){*exact=YES;return YES;}
        // Conflict is an observation, not proof of either active state or
        // retirement. Fresh active read/eligibility must establish retry.
        if(![retirementError.domain isEqual:@"com.socialbox.container-configuration-store"]||retirementError.code!=2){if(error)*error=retirementError;return NO;}
    }
    LBXContainerConfiguration *record=[_configurations configurationWithIdentifier:slot[@"configuration"][@"identifier"] absent:&absent
        inCurrentSourceOperationBeforeDeadline:deadline error:error];
    if(!record&&!absent)return NO;
    if(retire){
        if(![record.privateDictionary isEqual:slot[@"expected"]])return YES;
        if(![_configurations isConfigurationEditable:record inCurrentSourceOperationBeforeDeadline:deadline error:error])return NO;
        *retry=YES;return YES;
    }
    *exact=[record.privateDictionary isEqual:slot[@"configuration"]];
    *retry=([slot[@"operation"] isEqual:@"create"]&&absent)||([slot[@"operation"] isEqual:@"update"]&&[record.privateDictionary isEqual:slot[@"expected"]]);
    return YES;
}
- (BOOL)clear:(LBXContainerRootPendingTransaction *)transaction deadline:(double)deadline error:(NSError **)error {
    NSDictionary *prior=transaction.privateState,*pending=prior[@"pending"];
    NSString *epoch=Next(prior[@"epoch"]);if(!epoch)return NO;
    NSMutableDictionary *next=[prior mutableCopy];next[@"epoch"]=epoch;next[@"pending"]=NSNull.null;
    next[@"completed"]=@{@"slot":pending[@"slot"],@"input":pending[@"input"],@"proofSHA256":Proof(pending[@"slot"][@"configuration"])};
    LBXContainerConfiguration *candidate=[LBXContainerConfiguration fromDictionary:pending[@"slot"][@"configuration"] error:nil];
    // The checksum correlates private state; the current exact durable record
    // under configuration.lock supplies proof. Keep that lock through clear.
    BOOL (^publishClear)(NSDictionary *,NSError **)=^BOOL(NSDictionary *namespaceContext,NSError **proofError){
            (void)namespaceContext;return [transaction publishState:next error:proofError];
        };
    if([pending[@"slot"][@"operation"] isEqual:@"retire"])return [_configurations performWithExactRetirement:candidate
        inCurrentSourceOperationBeforeDeadline:deadline operation:publishClear error:error];
    return [_configurations performWithExactConfiguration:candidate inCurrentSourceOperationBeforeDeadline:deadline operation:publishClear error:error];
}
- (void)handleRequest:(NSDictionary *)request completion:(void (^)(NSDictionary *))completion {
    if(!completion)return;NSDictionary *snapshot=CopyJSON(request)?:@{};
    dispatch_async(_queue,^{
        if(!RootCaller()||!LBXContainerMutationIPCValidateRequest(snapshot,LBXContainerMutationIPCClock())){
            completion(LBXContainerMutationIPCFailure(snapshot,@"invalid_request"));return;}
        NSString *operation=snapshot[@"operation"];double deadline=[snapshot[@"deadline"] doubleValue];
        __block NSString *result=nil;__block NSDictionary *state=nil,*configuration=nil;__block NSArray *entries=nil;__block NSString *cursor=nil;
        NSError *error=nil;
        BOOL succeeded=[self->_owner performSourceOperation:^BOOL(NSError **effectError){
            if(!self->_pending)self->_pending=self->_installation?
                [LBXContainerRootPendingStore openDirectory:self->_directory licenseOwner:self->_owner configurationStore:self->_configurations
                    preparedInstallation:self->_installation create:NO beforeDeadline:deadline error:effectError]:
                [LBXContainerRootPendingStore openDirectory:self->_directory licenseOwner:self->_owner configurationStore:self->_configurations
                    create:NO beforeDeadline:deadline error:effectError];
            if(!self->_pending)return NO;
#if LBX_CONTAINER_ROOT_PENDING_TESTING
            [self->_pending testStopAfterBoundary:self->_stop];
#endif
            return [self->_pending withLockedStateBeforeDeadline:deadline operation:^BOOL(LBXContainerRootPendingTransaction *transaction,NSError **transactionError){
                NSDictionary *current=transaction.privateState;id pending=current[@"pending"],completed=current[@"completed"];
                BOOL (^finish)(NSString *,NSDictionary *)=^BOOL(NSString *outcome,NSDictionary *document){
                    state=[LBXContainerRootPendingStore projectState:transaction.privateState];configuration=document;result=outcome;return state!=nil;
                };
                if([operation isEqual:@"status"])return finish(@"status",nil);
                if([operation isEqual:@"list"]){
                    NSArray *records=[self->_configurations configurationsInCurrentSourceOperationBeforeDeadline:deadline error:transactionError];if(!records)return NO;
                    NSMutableArray *page=[NSMutableArray array];BOOL more=NO;NSString *after=snapshot[@"after"];
                    for(LBXContainerConfiguration *record in records){if(after.length&&[record.identifier compare:after]!=NSOrderedDescending)continue;
                        if(page.count==40){more=YES;break;}NSDictionary *entry=LBXContainerIPCListEntry(record.privateDictionary);if(!entry)return NO;[page addObject:entry];}
                    entries=[page copy];cursor=more?page.lastObject[@"identifier"]:@"";return finish(@"listed",nil);
                }
                if([operation isEqual:@"read"]){BOOL absent=NO;LBXContainerConfiguration *record=[self->_configurations
                    configurationWithIdentifier:snapshot[@"identifier"] absent:&absent inCurrentSourceOperationBeforeDeadline:deadline error:transactionError];
                    if(!record&&!absent)return NO;return finish(record?@"record":@"missing",record.privateDictionary);}
                if([operation hasPrefix:@"stage-"]){
                    BOOL retire=[operation isEqual:@"stage-retire"];
                    NSArray *keys=[operation isEqual:@"stage-create"]?@[@"expectedEmptyEpoch",@"stageRequestID",@"choices"]:
                        retire?@[@"expectedEmptyEpoch",@"stageRequestID",@"expected"]:@[@"expectedEmptyEpoch",@"stageRequestID",@"expected",@"configuration"];
                    NSDictionary *input=[snapshot dictionaryWithValuesForKeys:keys];
                    if(pending!=NSNull.null){
                        if([pending[@"input"] isEqual:input])return finish(retire?@"retirement_staged":@"staged",pending[@"slot"][@"configuration"]);
                        return finish(@"conflict",nil);
                    }
                    if(completed!=NSNull.null&&[completed[@"slot"][@"stageRequestID"] isEqual:snapshot[@"stageRequestID"]]){
                        if(![completed[@"input"] isEqual:input])return finish(@"conflict",nil);
                        BOOL exact=NO,retry=NO;if(![self readSlot:completed[@"slot"] deadline:deadline exact:&exact retry:&retry error:transactionError])return NO;
                        return finish(exact?(retire?@"retired":@"saved"):@"conflict",exact?completed[@"slot"][@"configuration"]:nil);
                    }
                    if(![current[@"epoch"] isEqual:snapshot[@"expectedEmptyEpoch"]])return finish(@"conflict",nil);
                    NSString *epoch=Next(current[@"epoch"]);if(!epoch)return NO;
                    BOOL create=[operation isEqual:@"stage-create"];LBXContainerConfiguration *candidate=nil;
                    if(create){NSDictionary *choices=snapshot[@"choices"];candidate=[LBXContainerConfiguration createWithName:choices[@"name"] applications:choices[@"applications"]
                        manualIdentifiers:choices[@"manualIdentifiers"]==NSNull.null?nil:choices[@"manualIdentifiers"] proxyReference:choices[@"proxyReference"] error:transactionError];}
                    else candidate=[LBXContainerConfiguration fromDictionary:snapshot[retire?@"expected":@"configuration"] error:transactionError];
                    if(!candidate)return NO;
                    NSDictionary *slot=@{@"token":NSUUID.UUID.UUIDString.lowercaseString,@"epoch":epoch,@"stageRequestID":snapshot[@"stageRequestID"],
                        @"operation":create?@"create":retire?@"retire":@"update",@"configuration":candidate.privateDictionary,@"expected":create?NSNull.null:snapshot[@"expected"]};
                    BOOL exact=NO,retry=NO;if(![self readSlot:slot deadline:deadline exact:&exact retry:&retry error:transactionError])return NO;
                    if(!retry)return finish(@"conflict",nil);
                    NSMutableDictionary *next=[current mutableCopy];next[@"epoch"]=epoch;next[@"pending"]=@{@"slot":slot,@"input":input,@"attempt":@0};
                    BOOL (^publishStage)(NSError **)=^BOOL(NSError **stageError){
                        if(![transaction publishState:next error:stageError])return NO;
                        return finish(retire?@"retirement_staged":@"staged",candidate.privateDictionary);
                    };
                    if(create)return publishStage(transactionError);
                    LBXContainerConfiguration *expected=[LBXContainerConfiguration fromDictionary:slot[@"expected"] error:nil];
                    return [self->_configurations performWithExactConfiguration:expected inCurrentSourceOperationBeforeDeadline:deadline
                        operation:^BOOL(NSDictionary *namespaceContext,NSError **stageError){
                            (void)namespaceContext;
                            if(![self->_configurations isConfigurationEditable:expected inCurrentSourceOperationBeforeDeadline:deadline error:stageError])return NO;
                            return publishStage(stageError);
                        } error:transactionError];
                }
                // Separate retirement commands prevent existing save/retry
                // consumers from executing or confirming a removal slot.
                BOOL retire=[@[@"execute-retire",@"reconcile-retire"] containsObject:operation];
                NSDictionary *slot=pending!=NSNull.null?pending[@"slot"]:completed!=NSNull.null?completed[@"slot"]:nil;
                if(!slot||![slot[@"token"] isEqual:snapshot[@"token"]]||![slot[@"epoch"] isEqual:snapshot[@"epoch"]])return finish(@"conflict",nil);
                if(retire!=[slot[@"operation"] isEqual:@"retire"])return finish(@"conflict",nil);
                BOOL exact=NO,retry=NO;if(![self readSlot:slot deadline:deadline exact:&exact retry:&retry error:transactionError])return NO;
                if(pending==NSNull.null)return finish(exact?(retire?@"retired":@"saved"):@"conflict",exact?slot[@"configuration"]:nil);
                if(exact){if(![self clear:transaction deadline:deadline error:transactionError])return NO;return finish(retire?@"retired":@"saved",slot[@"configuration"]);}
                if(!retry)return finish(@"conflict",nil);
                if([@[@"reconcile",@"reconcile-retire"] containsObject:operation])return finish(retire?@"retirement_retry_required":@"retry_required",slot[@"configuration"]);
                NSString *epoch=Next(current[@"epoch"]);if(!epoch||[pending[@"attempt"] longLongValue]==LLONG_MAX)return NO;
                NSMutableDictionary *attempt=[pending mutableCopy];attempt[@"attempt"]=@([pending[@"attempt"] longLongValue]+1);
                NSMutableDictionary *next=[current mutableCopy];next[@"epoch"]=epoch;next[@"pending"]=attempt;
                if(![transaction publishState:next error:transactionError])return NO;
                LBXContainerConfiguration *candidate=[LBXContainerConfiguration fromDictionary:slot[@"configuration"] error:nil];
                LBXContainerConfiguration *expected=slot[@"expected"]==NSNull.null?nil:[LBXContainerConfiguration fromDictionary:slot[@"expected"] error:nil];
                BOOL published=retire?[self->_configurations retireConfiguration:candidate inCurrentSourceOperationBeforeDeadline:deadline error:transactionError]:
                    [self->_configurations commitConfiguration:candidate replacing:expected inCurrentSourceOperationBeforeDeadline:deadline error:transactionError];
                if(!published)return NO;
                if(![self readSlot:slot deadline:deadline exact:&exact retry:&retry error:transactionError]||!exact)return NO;
                if(![self clear:transaction deadline:deadline error:transactionError])return NO;return finish(retire?@"retired":@"saved",slot[@"configuration"]);
            } error:effectError];
        } beforeDeadline:deadline error:&error];
        if(!succeeded){completion(LBXContainerMutationIPCFailure(snapshot,Failure(error)));return;}
        completion(LBXContainerMutationIPCReply(snapshot,result,state,configuration,entries,cursor));
    });
}
- (void)handleLegacyConfigurationQuery:(NSDictionary *)request completion:(void (^)(NSDictionary *))completion {
    if(!completion)return;NSDictionary *snapshot=CopyJSON(request)?:@{};
    if(!LBXContainerIPCValidateRequest(snapshot,LBXContainerIPCClock())||![@[@"read",@"list"] containsObject:snapshot[@"operation"]]){
        completion(LBXContainerIPCFailure(snapshot,@"invalid_request"));return;}
    NSMutableDictionary *translated=[snapshot mutableCopy];translated[@"family"]=@"container-mutation";
    [self handleRequest:translated completion:^(NSDictionary *reply){
        completion(LBXContainerIPCReply(snapshot,reply[@"result"],reply[@"configuration"]==NSNull.null?nil:reply[@"configuration"],reply[@"entries"],reply[@"next"]));
    }];
}
#if LBX_CONTAINER_ROOT_PENDING_TESTING
- (void)testStopAfterBoundary:(NSString *)boundary {_stop=[boundary copy];}
#endif
@end
