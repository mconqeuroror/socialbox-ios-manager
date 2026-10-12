#import "../Containers/LBXContainerIPC.h"
#import "../Containers/LBXContainerConfiguration.h"
#import <objc/runtime.h>
#include <limits.h>
#include <math.h>
static NSUInteger checks,failures,generations;
static void Check(BOOL value,NSString *message){checks++;if(!value){failures++;fprintf(stderr,"FAIL: %s\n",message.UTF8String);}}
static NSDictionary *Manual(void) {
    return @{@"serialNumber":@"c02abc123xyz",@"udid":@"0123456789abcdef0123456789abcdef01234567",
        @"idfa":@"01234567-89ab-4cde-8f01-23456789abcd",@"idfv":@"23456789-abcd-4ef0-8123-456789abcdef",
        @"platformUUID":@"3456789a-bcde-4f01-8234-56789abcdef0",@"wifiMac":@"02:ab:cd:ef:12:34",
        @"bluetoothMac":@"04:12:34:56:78:9a",@"imei":@"490154203237518",@"meid":@"a1000000000001",@"iccid":@"8914800000000000014"};
}
static NSMutableDictionary *Replace(NSDictionary *value,NSString *key,id replacement) {
    NSMutableDictionary *copy=[value mutableCopy];if(replacement)copy[key]=replacement;else[copy removeObjectForKey:key];return copy;
}
static BOOL RequestRejected(id value){return !LBXContainerIPCValidateRequest(value,LBXContainerIPCClock());}
static BOOL ReplyRejected(id value,NSDictionary *request){return !LBXContainerIPCValidateReply(value,request,LBXContainerIPCClock());}
static id ForbiddenGeneration(__unused id receiver,__unused SEL selector,__unused NSString *name,__unused NSArray *apps,
    __unused NSDictionary *manual,__unused NSString *proxy,__unused NSError **error){generations++;return nil;}
int main(void){@autoreleasepool{
    NSArray *apps=@[@"com.burbn.instagram",@"com.facebook.Facebook",@"com.atebits.Tweetie2"];
    NSString *proxy=@"abcdef01-2345-4678-9abc-def012345678";
    LBXContainerConfiguration *manual=[LBXContainerConfiguration createWithName:@"private-name" applications:apps manualIdentifiers:Manual() proxyReference:proxy error:nil];
    LBXContainerConfiguration *random=[LBXContainerConfiguration createWithName:@"private-name" applications:apps manualIdentifiers:nil proxyReference:proxy error:nil];
    LBXContainerConfiguration *edited=[manual configurationByUpdatingName:@"edited" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    Method generator=class_getClassMethod(LBXContainerConfiguration.class,@selector(createWithName:applications:manualIdentifiers:proxyReference:error:));
    IMP original=method_setImplementation(generator,(IMP)ForbiddenGeneration);
    NSDictionary *choices=@{@"name":@"private-name",@"applications":apps,@"manualIdentifiers":Manual(),@"proxyReference":proxy};
    NSDictionary *prepare=LBXContainerIPCRequest(@"prepare",@{@"choices":choices});
    NSDictionary *create=LBXContainerIPCRequest(@"create",@{@"configuration":manual.privateDictionary});
    NSDictionary *update=LBXContainerIPCRequest(@"update",@{@"expected":manual.privateDictionary,@"configuration":edited.privateDictionary});
    NSDictionary *read=LBXContainerIPCRequest(@"read",@{@"identifier":manual.identifier});
    NSDictionary *list=LBXContainerIPCRequest(@"list",@{@"after":@""});
    for(NSDictionary *request in @[prepare,create,update,read,list]) {
        Check(LBXContainerIPCValidateRequest(request,LBXContainerIPCClock()),@"each strict request operation is valid");
        for(NSString *field in @[@"family",@"version",@"requestID",@"operation",@"deadline"])
            Check(RequestRejected(Replace(request,field,nil)),@"all envelope fields are mandatory");
        for(NSString *extra in @[@"path",@"receipt",@"licenseToken",@"engineAuthorized",@"deviceId"])
            Check(RequestRejected(Replace(request,extra,@"private-caller-value")),@"extra authority or path fields are rejected");
    }
    Check(RequestRejected(@[])&&RequestRejected(NSNull.null),@"non-dictionary requests reject safely");
    for(id version in @[@YES,@"1",@1.0,@2])Check(RequestRejected(Replace(create,@"version",version)),@"protocol version is exact non-Boolean integer one");
    for(id identifier in @[@"wrong",manual.identifier.uppercaseString,@"00000000-0000-0000-0000-000000000000",@42])
        Check(RequestRejected(Replace(create,@"requestID",identifier)),@"request UUID has canonical nonzero lowercase format");
    Check(RequestRejected(Replace(create,@"family",@"license"))&&RequestRejected(Replace(create,@"operation",@"activate")),@"foreign families and operations cannot route as configuration");
    for(id deadline in @[@YES,@"tomorrow",@(NAN),@(INFINITY),@(LBXContainerIPCClock()-1),@(LBXContainerIPCClock()+26)])
        Check(RequestRejected(Replace(create,@"deadline",deadline)),@"deadlines are finite bounded numeric absolute values");
    Check(!LBXContainerIPCValidateRequest(create,NAN)&&!LBXContainerIPCValidateRequest(create,-1),@"invalid local clocks cannot accept a request");
    Check(!LBXContainerIPCValidateRequest(create,[create[@"deadline"] doubleValue]),@"request expires exactly at its original deadline");
    Check(!LBXContainerIPCRequest(@"read",@{@"identifier":manual.identifier,@"deadline":@1}),@"factory cannot replace its generated envelope");
    Check(!LBXContainerIPCRequest(@"create",@{@"configuration":edited.privateDictionary}),@"create requires first revision");
    for(NSString *key in choices)
        Check(RequestRejected(Replace(prepare,@"choices",Replace(choices,key,nil))),@"every preparation choice is required");
    Check(RequestRejected(Replace(prepare,@"choices",Replace(choices,@"proxyReference",@"http://secret@proxy"))),@"choice proxy is a handle instead of a credential URL");
    Check(RequestRejected(Replace(prepare,@"choices",Replace(choices,@"manualIdentifiers",@{}))),@"partial manual identity is invalid");
    Check(RequestRejected(Replace(prepare,@"choices",Replace(choices,@"extra",@1))),@"preparation choices reject unknown fields");
    NSDictionary *randomChoices=Replace(choices,@"manualIdentifiers",NSNull.null);
    NSDictionary *randomPrepare=LBXContainerIPCRequest(@"prepare",@{@"choices":randomChoices});
    Check(randomPrepare&&LBXContainerIPCValidateRequest(randomPrepare,LBXContainerIPCClock()),@"NSNull explicitly requests random preparation without generating");
    for(id bad in @[@YES,@1.0,@(-1),@0])
        Check(RequestRejected(Replace(create,@"configuration",Replace(manual.privateDictionary,@"revision",bad))),@"configuration revisions reject Boolean float negative and zero values");
    Check(RequestRejected(Replace(create,@"configuration",Replace(manual.privateDictionary,@"identifier",manual.identifier.uppercaseString))),@"container storage keys are canonical");
    Check(RequestRejected(Replace(create,@"configuration",Replace(manual.privateDictionary,@"applications",@[apps[2],apps[0],apps[1]]))),@"complete configuration document uses canonical app order");
    Check(RequestRejected(Replace(update,@"expected",edited.privateDictionary)),@"update cannot retain the expected revision");
    Check(RequestRejected(Replace(update,@"configuration",Replace(edited.privateDictionary,@"revision",@3))),@"update advances exactly one revision");
    Check(RequestRejected(Replace(update,@"configuration",Replace(edited.privateDictionary,@"identifier",random.identifier))),@"update cannot replace a different stable container");
    NSMutableDictionary *maximum=Replace(manual.privateDictionary,@"revision",@(LLONG_MAX));
    Check(!LBXContainerIPCRequest(@"update",@{@"expected":maximum,@"configuration":maximum}),@"revision overflow is rejected");
    Check(RequestRejected(Replace(read,@"identifier",@"../private"))&&RequestRejected(Replace(list,@"after",@YES)),@"read keys and list cursors cannot select paths or coerce types");
    NSDictionary *prepared=LBXContainerIPCReply(prepare,@"prepared",manual.privateDictionary,nil,nil);
    NSDictionary *saved=LBXContainerIPCReply(create,@"saved",manual.privateDictionary,nil,nil);
    NSDictionary *updated=LBXContainerIPCReply(update,@"saved",edited.privateDictionary,nil,nil);
    NSDictionary *record=LBXContainerIPCReply(read,@"record",manual.privateDictionary,nil,nil);
    NSDictionary *empty=LBXContainerIPCReply(list,@"listed",nil,@[],@"");
    for(NSArray *pair in @[@[prepare,prepared],@[create,saved],@[update,updated],@[read,record],@[list,empty]]) {
        NSDictionary *request=pair[0],*reply=pair[1];
        Check(LBXContainerIPCValidateReply(reply,request,LBXContainerIPCClock()),@"successful reply matches its exact request context");
        for(NSString *field in @[@"family",@"version",@"requestID",@"operation",@"result",@"runtimeAccepted",@"configuration",@"entries",@"next"])
            Check(ReplyRejected(Replace(reply,field,nil),request),@"every exact reply field is mandatory");
        for(NSString *extra in @[@"message",@"key",@"bearer",@"licenseToken",@"engineAuthorized"])
            Check(ReplyRejected(Replace(reply,extra,@"private-response-value"),request),@"reply cannot carry credentials arbitrary text or engine flags");
        Check(ReplyRejected(Replace(reply,@"requestID",NSUUID.UUID.UUIDString.lowercaseString),request),@"foreign correlation UUID rejects reply");
        Check(ReplyRejected(Replace(reply,@"family",@"license"),request),@"foreign response family rejects reply");
        for(id flag in @[@YES,@0,@1,@"false"])
            Check(ReplyRejected(Replace(reply,@"runtimeAccepted",flag),request),@"runtime support is exact Boolean false and never a grant");
        Check(!LBXContainerIPCValidateReply(reply,request,[request[@"deadline"] doubleValue]),@"late replies cannot satisfy request deadline");
    }
    Check(LBXContainerIPCValidateReply(LBXContainerIPCReply(randomPrepare,@"prepared",random.privateDictionary,nil,nil),randomPrepare,LBXContainerIPCClock()),@"validated random preparation matches random mode and selected choices");
    Check(ReplyRejected(Replace(prepared,@"configuration",random.privateDictionary),prepare),@"random identity cannot replace exact manual choice reply");
    Check(ReplyRejected(Replace(prepared,@"configuration",Replace(manual.privateDictionary,@"name",@"different")),prepare),@"prepared name must match submitted choice");
    Check(ReplyRejected(Replace(saved,@"configuration",random.privateDictionary),create),@"saved reply cannot substitute another UUID or random values");
    Check(ReplyRejected(Replace(updated,@"configuration",manual.privateDictionary),update),@"update result is the exact proposed next document");
    Check(ReplyRejected(Replace(record,@"configuration",random.privateDictionary),read),@"read reply returns only requested stable UUID");
    Check(ReplyRejected(Replace(saved,@"result",@"record"),create),@"success results cannot cross operations");
    for(NSString *result in @[@"conflict",@"authorization_required",@"storage_unavailable",@"invalid_request",@"service_unavailable",@"unconfirmed"]) {
        NSDictionary *failure=LBXContainerIPCFailure(create,result);
        Check(LBXContainerIPCValidateReply(failure,create,LBXContainerIPCClock()),@"fixed failure result is valid and empty");
        Check(failure[@"configuration"]==NSNull.null&&[failure[@"entries"] count]==0&&![failure[@"next"] length],@"failure contains no private configuration or page");
        Check(ReplyRejected(Replace(failure,@"configuration",manual.privateDictionary),create),@"failed result cannot disclose a configuration");
    }
    Check(LBXContainerIPCValidateReply(LBXContainerIPCFailure(read,@"missing"),read,LBXContainerIPCClock()),@"missing is an explicit read-only result");
    Check([LBXContainerIPCFailure(create,@"missing")[@"result"] isEqual:@"service_unavailable"],@"missing cannot masquerade as a create outcome");
    Check([LBXContainerIPCFailure(create,@"saved")[@"result"] isEqual:@"service_unavailable"],@"error factory cannot forge successful save");
    Check([LBXContainerIPCFailure(create,@"private-server-error")[@"result"] isEqual:@"service_unavailable"],@"unknown errors are normalized instead of echoed");
    Check([LBXContainerIPCReply(create,@"saved",random.privateDictionary,nil,nil)[@"result"] isEqual:@"service_unavailable"],@"reply helper refuses mismatched success payload");
    NSDictionary *entry=LBXContainerIPCListEntry(manual.privateDictionary);
    Check(entry.count==4&&!entry[@"identifiers"]&&!entry[@"proxyReference"]&&[entry[@"name"] isEqual:manual.name],@"list projection omits identity/proxy while retaining requested display fields");
    NSMutableArray *page=[NSMutableArray array];
    for(NSUInteger i=1;i<=40;i++) {
        NSString *identifier=[NSString stringWithFormat:@"00000000-0000-4000-8000-%012lu",(unsigned long)i];
        [page addObject:Replace(entry,@"identifier",identifier)];
    }
    NSString *last=page.lastObject[@"identifier"];
    NSDictionary *listed=LBXContainerIPCReply(list,@"listed",nil,page,last);
    Check(LBXContainerIPCValidateReply(listed,list,LBXContainerIPCClock()),@"full sorted page uses last stable ID as continuation cursor");
    Check(ReplyRejected(Replace(listed,@"next",page.firstObject[@"identifier"]),list),@"page cursor cannot repeat an earlier item");
    Check(ReplyRejected(Replace(listed,@"entries",[[page reverseObjectEnumerator] allObjects]),list),@"out-of-order page entries reject");
    NSMutableArray *duplicates=[page mutableCopy];duplicates[1]=duplicates[0];
    Check(ReplyRejected(Replace(listed,@"entries",duplicates),list),@"duplicate stable IDs reject page");
    NSMutableArray *tooMany=[page mutableCopy];[tooMany addObject:entry];
    Check(ReplyRejected(Replace(listed,@"entries",tooMany),list),@"list payload never exceeds forty entries");
    Check(ReplyRejected(Replace(listed,@"entries",@[entry]),list),@"short page cannot claim continuation");
    NSMutableArray *extraEntry=[page mutableCopy];extraEntry[0]=Replace(extraEntry[0],@"proxyReference",proxy);
    Check(ReplyRejected(Replace(listed,@"entries",extraEntry),list),@"list entries cannot carry private extra fields");
    for(id revision in @[@YES,@1.0,@0]) {
        NSMutableArray *bad=[page mutableCopy];bad[0]=Replace(bad[0],@"revision",revision);
        Check(ReplyRejected(Replace(listed,@"entries",bad),list),@"page revisions reject coercion");
    }
    NSDictionary *nextRequest=LBXContainerIPCRequest(@"list",@{@"after":last});
    Check(ReplyRejected(Replace(listed,@"requestID",nextRequest[@"requestID"]),nextRequest),@"next page excludes all identifiers at or before submitted cursor");
    Check(ReplyRejected(Replace(empty,@"configuration",manual.privateDictionary),list),@"list cannot disclose a full private configuration");
    NSString *maximumUnicode=[@"界" stringByPaddingToLength:80 withString:@"界" startingAtIndex:0];
    NSMutableArray *unicodePage=[NSMutableArray array];
    for(NSDictionary *item in page) {
        NSMutableDictionary *maximumEntry=Replace(item,@"name",maximumUnicode);
        maximumEntry[@"revision"]=@(LLONG_MAX);maximumEntry[@"applications"]=apps;
        [unicodePage addObject:maximumEntry];
    }
    NSDictionary *largePage=Replace(listed,@"entries",unicodePage);
    NSData *largeEncoded=[NSJSONSerialization dataWithJSONObject:largePage options:0 error:nil];
    Check(largeEncoded.length>16384&&largeEncoded.length<=65536,@"legal forty-entry Unicode page crosses the request limit but fits reply limit");
    NSDictionary *largeReply=LBXContainerIPCReply(list,@"listed",nil,unicodePage,last);
    Check([largeReply[@"result"] isEqual:@"listed"]&&LBXContainerIPCValidateReply(largeReply,list,LBXContainerIPCClock()),@"maximum Unicode names and all memberships return an accepted full page");
    Check([largeReply[@"next"] isEqual:last]&&[largeReply[@"entries"] count]==40,@"large reply retains exact forty-item pagination cursor");
    NSMutableArray *oversizedPage=[unicodePage mutableCopy];
    oversizedPage[0]=Replace(oversizedPage[0],@"name",[@"x" stringByPaddingToLength:65536 withString:@"x" startingAtIndex:0]);
    NSDictionary *oversized=Replace(largePage,@"entries",oversizedPage);
    Check([NSJSONSerialization dataWithJSONObject:oversized options:0 error:nil].length>65536&&ReplyRejected(oversized,list),@"over-64-KiB reply is rejected before private entry processing");
    Check([LBXContainerIPCReply(list,@"listed",nil,oversizedPage,last)[@"result"] isEqual:@"service_unavailable"],@"oversized success construction returns only fixed empty failure");
    NSArray *wrongTypes=@[NSNull.null,@YES,@42,@1.5,@"wrong",@[NSNull.null],@{@"unexpected":@"field"}];
    for(NSString *field in @[@"family",@"version",@"requestID",@"operation",@"deadline",@"choices"]) {
        for(id wrong in wrongTypes)Check(RequestRejected(Replace(prepare,field,wrong)),@"request envelope rejects every incompatible JSON value type");
    }
    for(NSString *field in @[@"name",@"applications",@"manualIdentifiers",@"proxyReference"]) {
        for(id wrong in wrongTypes) {
            if([field isEqual:@"name"]&&[wrong isKindOfClass:NSString.class])continue;
            if([field isEqual:@"manualIdentifiers"]&&wrong==NSNull.null)continue;
            Check(RequestRejected(Replace(prepare,@"choices",Replace(choices,field,wrong))),@"pure choice validation rejects incompatible JSON value types");
        }
    }
    for(NSString *field in @[@"family",@"version",@"requestID",@"operation",@"result",@"runtimeAccepted",@"configuration",@"entries",@"next"]) {
        for(id wrong in wrongTypes)Check(ReplyRejected(Replace(saved,field,wrong),create),@"reply schema rejects every incompatible JSON value type");
    }
    NSMutableDictionary *numericRequest=[prepare mutableCopy];[numericRequest removeObjectForKey:@"choices"];numericRequest[@1]=choices;
    Check(RequestRejected(numericRequest),@"non-string request keys cannot alias required JSON fields");
    NSMutableDictionary *numericChoices=[choices mutableCopy];[numericChoices removeObjectForKey:@"name"];numericChoices[@1]=@"private-name";
    Check(RequestRejected(Replace(prepare,@"choices",numericChoices)),@"choice key types are strict before pure field validation");
    NSMutableDictionary *numericReply=[saved mutableCopy];[numericReply removeObjectForKey:@"result"];numericReply[@1]=@"saved";
    Check(ReplyRejected(numericReply,create),@"non-string response keys cannot alias result fields");
    Check(!LBXContainerIPCRequest(@"list",@{@1:@"value"}),@"request factory rejects non-string argument keys");
    NSMutableDictionary *oversizedRequest=Replace(prepare,@"choices",Replace(choices,@"name",[@"x" stringByPaddingToLength:16384 withString:@"x" startingAtIndex:0]));
    Check([NSJSONSerialization dataWithJSONObject:oversizedRequest options:0 error:nil].length>16384&&RequestRejected(oversizedRequest),@"request limit remains sixteen KiB independently of the larger response bound");
    NSMutableDictionary *mutableChoices=[choices mutableCopy];NSMutableArray *mutableApps=[apps mutableCopy];mutableChoices[@"applications"]=mutableApps;
    NSDictionary *snapshot=LBXContainerIPCRequest(@"prepare",@{@"choices":mutableChoices});
    [mutableApps removeAllObjects];mutableChoices[@"name"]=@"changed";
    Check([snapshot[@"choices"][@"name"] isEqual:@"private-name"]&&[snapshot[@"choices"][@"applications"] count]==3,@"factory deep-snapshots mutable private input");
    Check(generations==0,@"request/reply validation and projection never invokes identity generation");
    method_setImplementation(generator,original);
    NSLog(@"%@: %lu container IPC assertions, %lu failures",failures?@"FAIL":@"PASS",(unsigned long)checks,(unsigned long)failures);return failures?1:0;
}}
