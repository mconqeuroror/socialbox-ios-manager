#import "LBXContainerOwner.h"
#import "LBXContainerIPC.h"
#import "LBXContainerConfiguration.h"
#import "LBXContainerConfigurationStore.h"
#import "../Authorization/LBXLicenseOwner.h"

static NSString *ReadFailure(NSError *error) {
    if([error.domain isEqual:@"com.socialbox.source-operation"]&&error.code==4)return @"authorization_required";
    if([error.domain isEqual:@"com.socialbox.source-operation"]&&[ @[@1,@3] containsObject:@(error.code)])return @"unconfirmed";
    return @"storage_unavailable";
}
static NSString *SaveFailure(NSError *error) {
    if([error.domain isEqual:@"com.socialbox.container-configuration-store"]&&error.code==2)return @"conflict";
    if(([error.domain isEqual:@"com.socialbox.source-operation"]&&error.code==4)||
       ([error.domain isEqual:@"com.socialbox.container-configuration-store"]&&error.code==4))return @"authorization_required";
    // Publication can precede a failed sync/readback/final assessment. Never
    // turn an unknown outcome into "not saved" or prepare a fresh identity.
    return @"unconfirmed";
}
@implementation LBXContainerOwner {
    LBXLicenseOwner *_license;
    LBXContainerConfigurationStore *_store;
    dispatch_queue_t _queue;
}
- (instancetype)initWithLicenseOwner:(LBXLicenseOwner *)owner store:(LBXContainerConfigurationStore *)store {
    if(![owner isKindOfClass:LBXLicenseOwner.class]||(store&&(![store isKindOfClass:LBXContainerConfigurationStore.class]||![store usesLicenseOwner:owner])))return nil;
    if((self=[super init])){_license=owner;_store=store;_queue=dispatch_queue_create("com.socialbox.container.owner",DISPATCH_QUEUE_SERIAL);}return self;
}
- (NSString *)description {return @"<LBXContainerOwner: private source configuration consumer>";}
- (NSString *)debugDescription {return self.description;}
- (void)handleRequest:(NSDictionary *)request completion:(void (^)(NSDictionary *))completion {
    if(!completion)return;
    NSData *data=[NSJSONSerialization isValidJSONObject:request]?[NSJSONSerialization dataWithJSONObject:request options:0 error:nil]:nil;
    id parsed=data.length&&data.length<=32768?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    NSDictionary *snapshot=[parsed isKindOfClass:NSDictionary.class]?parsed:@{};
    dispatch_async(_queue,^{
        void (^failure)(NSString *)=^(NSString *result){completion(LBXContainerIPCFailure(snapshot,result));};
        if(!LBXContainerIPCValidateRequest(snapshot,LBXContainerIPCClock())){failure(@"invalid_request");return;}
        NSString *operation=snapshot[@"operation"];double deadline=[snapshot[@"deadline"] doubleValue];NSError *error=nil;
        if([operation isEqual:@"prepare"]){
            __block LBXContainerConfiguration *configuration=nil;
            BOOL prepared=[self->_license performSourceOperation:^BOOL(NSError **effectError){
                NSDictionary *choices=snapshot[@"choices"];id manual=choices[@"manualIdentifiers"];
                configuration=[LBXContainerConfiguration createWithName:choices[@"name"] applications:choices[@"applications"] manualIdentifiers:manual==NSNull.null?nil:manual proxyReference:choices[@"proxyReference"] error:effectError];
                return configuration!=nil;
            } beforeDeadline:deadline error:&error];
            if(!prepared){failure(ReadFailure(error));return;}
            completion(LBXContainerIPCReply(snapshot,@"prepared",configuration.privateDictionary,@[],@""));return;
        }
        if(!self->_store){failure(@"storage_unavailable");return;}
        if([operation isEqual:@"list"]){
            __block NSArray *records=nil;
            BOOL read=[self->_license performSourceOperation:^BOOL(NSError **effectError){records=[self->_store configurations:effectError];return records!=nil;} beforeDeadline:deadline error:&error];
            if(!read){failure(ReadFailure(error));return;}
            NSString *after=snapshot[@"after"];NSMutableArray *page=[NSMutableArray array];BOOL more=NO;
            for(LBXContainerConfiguration *record in records) {
                if(after.length&&[record.identifier compare:after]!=NSOrderedDescending)continue;
                if(page.count==40){more=YES;break;}
                NSDictionary *entry=LBXContainerIPCListEntry(record.privateDictionary);if(!entry){failure(@"storage_unavailable");return;}[page addObject:entry];
            }
            completion(LBXContainerIPCReply(snapshot,@"listed",nil,page,more?page.lastObject[@"identifier"]:@""));return;
        }
        NSString *identifier=[operation isEqual:@"read"]?snapshot[@"identifier"]:snapshot[@"configuration"][@"identifier"];
        __block LBXContainerConfiguration *current=nil;__block BOOL absent=NO;
        BOOL inspected=[self->_license performSourceOperation:^BOOL(NSError **effectError){
            current=[self->_store configurationWithIdentifier:identifier absent:&absent error:effectError];return current!=nil||absent;
        } beforeDeadline:deadline error:&error];
        if(!inspected){failure(ReadFailure(error));return;}
        if([operation isEqual:@"read"]){
            completion(LBXContainerIPCReply(snapshot,current?@"record":@"missing",current.privateDictionary,@[],@""));return;
        }
        LBXContainerConfiguration *candidate=[LBXContainerConfiguration fromDictionary:snapshot[@"configuration"] error:nil];
        if([current.privateDictionary isEqual:candidate.privateDictionary]){
            // Same stable UUID and exact document: an already-published create
            // or update is a confirmed retry, with no regeneration or write.
            completion(LBXContainerIPCReply(snapshot,@"saved",current.privateDictionary,@[],@""));return;
        }
        BOOL create=[operation isEqual:@"create"];
        LBXContainerConfiguration *expected=create?nil:[LBXContainerConfiguration fromDictionary:snapshot[@"expected"] error:nil];
        if(create?!absent:![current.privateDictionary isEqual:expected.privateDictionary]){failure(@"conflict");return;}
        // Never nest an outer licensing fence around commit: the store enters
        // that same owner once and rechecks after any intervening validation.
        if(![self->_store commitConfiguration:candidate replacing:expected beforeDeadline:deadline error:&error]){failure(SaveFailure(error));return;}
        completion(LBXContainerIPCReply(snapshot,@"saved",candidate.privateDictionary,@[],@""));
    });
}
@end
