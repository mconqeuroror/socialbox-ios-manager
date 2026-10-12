#import "../Containers/LBXContainerMutationIPC.h"
#import "../Containers/LBXContainerIPC.h"
#import "../Containers/LBXContainerConfiguration.h"
#import <objc/runtime.h>
#include <limits.h>
#include <math.h>
static NSUInteger Checks,Failures,Generations;
static void Check(BOOL value,NSString *label){Checks++;if(!value){Failures++;fprintf(stderr,"FAIL: %s\n",label.UTF8String);}}
static NSMutableDictionary *Replace(NSDictionary *value,NSString *key,id replacement){NSMutableDictionary *copy=[value mutableCopy];if(replacement)copy[key]=replacement;else[copy removeObjectForKey:key];return copy;}
static NSDictionary *Slot(NSDictionary *configuration,NSDictionary *expected,NSString *epoch,NSString *stageID){return @{@"token":NSUUID.UUID.UUIDString.lowercaseString,@"epoch":epoch,@"stageRequestID":stageID,@"operation":expected?@"update":@"create",@"configuration":configuration,@"expected":expected?:NSNull.null};}
static NSDictionary *State(NSString *epoch,NSDictionary *pending,NSDictionary *completed){return @{@"epoch":epoch,@"pending":pending?:NSNull.null,@"completed":completed?:NSNull.null};}
static BOOL BadRequest(id value){return !LBXContainerMutationIPCValidateRequest(value,LBXContainerMutationIPCClock());}
static BOOL BadReply(id value,NSDictionary *request){return !LBXContainerMutationIPCValidateReply(value,request,LBXContainerMutationIPCClock());}
static id NoGeneration(__unused id receiver,__unused SEL selector,__unused NSString *name,__unused NSArray *apps,__unused NSDictionary *manual,__unused NSString *proxy,__unused NSError **error){Generations++;return nil;}
static void ProxyMetadataTests(LBXContainerConfiguration *original) {
    NSString *reference=@"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",*other=@"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    NSDictionary *document=Replace(original.privateDictionary,@"proxyReference",reference);
    NSDictionary *choices=@{@"name":original.name,@"applications":original.applications,@"manualIdentifiers":original.identifiers,@"proxyReference":reference};
    NSDictionary *create=LBXContainerMutationIPCRequest(@"stage-create",@{@"expectedEmptyEpoch":@"1",@"stageRequestID":NSUUID.UUID.UUIDString.lowercaseString,@"choices":choices});
    Check(create&&[create[@"choices"] isEqual:choices],@"canonical proxy UUID is retained as authored choices without resolving it");
    if(!create)return;
    NSDictionary *slot=Slot(document,nil,@"2",create[@"stageRequestID"]),*pending=State(@"2",slot,nil),*completed=State(@"3",nil,slot);
    for(NSString *result in @[@"staged",@"saved"]){
        NSDictionary *reply=LBXContainerMutationIPCReply(create,result,[result isEqual:@"staged"]?pending:completed,document,nil,nil);
        Check([reply[@"result"] isEqual:result]&&!BadReply(reply,create)&&[reply[@"configuration"] isEqual:document],@"stage and duplicate-completed create bind exact proxy choice and full document");
        NSDictionary *different=Replace(document,@"proxyReference",other),*changedSlot=Replace(slot,@"configuration",different);
        NSDictionary *bad=Replace(Replace(reply,@"configuration",different),@"state",[result isEqual:@"staged"]?State(@"2",changedSlot,nil):State(@"3",nil,changedSlot));
        Check(BadReply(bad,create),@"matching correlation/name/manual fields cannot acknowledge a different canonical proxy reference");
    }
    for(NSString *operation in @[@"execute",@"reconcile"]){
        NSDictionary *request=LBXContainerMutationIPCRequest(operation,@{@"token":slot[@"token"],@"epoch":slot[@"epoch"]});
        NSString *result=[operation isEqual:@"execute"]?@"saved":@"retry_required";
        NSDictionary *reply=LBXContainerMutationIPCReply(request,result,[operation isEqual:@"execute"]?completed:pending,document,nil,nil);
        Check([reply[@"result"] isEqual:result]&&!BadReply(reply,request)&&[reply[@"configuration"] isEqual:document],@"execute and reconcile carry opaque reference in exact retained slot");
    }
    NSDictionary *status=LBXContainerMutationIPCRequest(@"status",@{}),*read=LBXContainerMutationIPCRequest(@"read",@{@"identifier":original.identifier});
    Check([LBXContainerMutationIPCReply(status,@"status",pending,nil,nil,nil)[@"state"] isEqual:pending],@"status projects nonempty proxy in exact full pending document");
    Check([LBXContainerMutationIPCReply(read,@"record",completed,document,nil,nil)[@"configuration"] isEqual:document],@"full read preserves canonical proxy reference");
    NSDictionary *next=Replace(Replace(document,@"revision",@2),@"proxyReference",other);
    NSDictionary *update=LBXContainerMutationIPCRequest(@"stage-update",@{@"expectedEmptyEpoch":@"3",@"stageRequestID":NSUUID.UUID.UUIDString.lowercaseString,@"expected":document,@"configuration":next});
    NSDictionary *updateSlot=Slot(next,document,@"4",update[@"stageRequestID"]);
    Check(update&&[LBXContainerMutationIPCReply(update,@"staged",State(@"4",updateSlot,slot),next,nil,nil)[@"result"] isEqual:@"staged"],@"existing exact full-document update transports old and new canonical references");
    NSDictionary *retire=LBXContainerMutationIPCRequest(@"stage-retire",@{@"expectedEmptyEpoch":@"3",@"stageRequestID":NSUUID.UUID.UUIDString.lowercaseString,@"expected":document});
    NSMutableDictionary *retireSlot=[Slot(document,document,@"4",retire[@"stageRequestID"]) mutableCopy];retireSlot[@"operation"]=@"retire";
    Check(retire&&[LBXContainerMutationIPCReply(retire,@"retirement_staged",State(@"4",retireSlot,slot),document,nil,nil)[@"result"] isEqual:@"retirement_staged"],@"retirement transports exact original nonempty reference without a revision increment");
    for(id invalid in @[NSNull.null,@YES,@1,@[],reference.uppercaseString,@"00000000-0000-0000-0000-000000000000",@"https://host",@"user:password@host",@"not-a-reference",[reference stringByAppendingString:@" "]]){
        NSDictionary *badChoices=Replace(choices,@"proxyReference",invalid),*badDocument=Replace(document,@"proxyReference",invalid);
        Check(!LBXContainerMutationIPCRequest(@"stage-create",@{@"expectedEmptyEpoch":@"1",@"stageRequestID":create[@"stageRequestID"],@"choices":badChoices}),@"malformed uppercase URL credential or coerced proxy choice refuses");
        Check(!LBXContainerMutationIPCRequest(@"stage-retire",@{@"expectedEmptyEpoch":@"3",@"stageRequestID":retire[@"stageRequestID"],@"expected":badDocument})&&!LBXContainerMutationIPCProjectSlot(Replace(slot,@"configuration",badDocument)),@"malformed proxy cannot cross full-document or status slot parser");
    }
}
int main(void){@autoreleasepool{
    NSArray *apps=@[@"com.burbn.instagram",@"com.facebook.Facebook",@"com.atebits.Tweetie2"];
    LBXContainerConfiguration *random=[LBXContainerConfiguration createWithName:@"Synthetic random" applications:apps manualIdentifiers:nil proxyReference:@"" error:nil];
    LBXContainerConfiguration *manual=[LBXContainerConfiguration createWithName:@"Synthetic manual" applications:apps manualIdentifiers:random.identifiers proxyReference:@"" error:nil];
    LBXContainerConfiguration *updated=[manual configurationByUpdatingName:@"Synthetic edit" applications:nil manualIdentifiers:nil proxyReference:nil error:nil];
    NSString *stageID=NSUUID.UUID.UUIDString.lowercaseString;
    NSDictionary *choices=@{@"name":manual.name,@"applications":apps,@"manualIdentifiers":manual.identifiers,@"proxyReference":@""};
    NSDictionary *create=LBXContainerMutationIPCRequest(@"stage-create",@{@"expectedEmptyEpoch":@"1",@"stageRequestID":stageID,@"choices":choices});
    NSDictionary *update=LBXContainerMutationIPCRequest(@"stage-update",@{@"expectedEmptyEpoch":@"5",@"stageRequestID":NSUUID.UUID.UUIDString.lowercaseString,@"expected":manual.privateDictionary,@"configuration":updated.privateDictionary});
    NSDictionary *slot=Slot(manual.privateDictionary,nil,@"2",stageID),*pending=State(@"4",slot,nil),*completed=State(@"5",nil,slot);
    NSDictionary *newSlot=Slot(updated.privateDictionary,manual.privateDictionary,@"6",update[@"stageRequestID"]),*newPending=State(@"7",newSlot,slot);
    NSDictionary *status=LBXContainerMutationIPCRequest(@"status",@{});
    NSDictionary *execute=LBXContainerMutationIPCRequest(@"execute",@{@"token":slot[@"token"],@"epoch":slot[@"epoch"]});
    NSDictionary *reconcile=LBXContainerMutationIPCRequest(@"reconcile",@{@"token":slot[@"token"],@"epoch":slot[@"epoch"]});
    NSDictionary *read=LBXContainerMutationIPCRequest(@"read",@{@"identifier":manual.identifier});
    NSDictionary *list=LBXContainerMutationIPCRequest(@"list",@{@"after":@""});
    Method generator=class_getClassMethod(LBXContainerConfiguration.class,@selector(createWithName:applications:manualIdentifiers:proxyReference:error:));
    IMP original=method_setImplementation(generator,(IMP)NoGeneration);
    NSArray *requests=@[status,create,update,execute,reconcile,read,list];
    for(NSDictionary *request in requests){
        Check(!BadRequest(request),@"each exact operation is valid");
        Check(!LBXContainerIPCValidateRequest(request,LBXContainerIPCClock()),@"new family never routes through old configuration validator");
        for(NSString *field in @[@"family",@"version",@"requestID",@"operation",@"deadline"])Check(BadRequest(Replace(request,field,nil)),@"all envelope fields are mandatory");
        for(NSString *field in @[@"UID",@"euid",@"path",@"key",@"receipt",@"context",@"generation",@"phase",@"attempt",@"engineAuthorized"])Check(BadRequest(Replace(request,field,@1)),@"caller authority and private context fields are rejected");
        Check(!LBXContainerMutationIPCValidateRequest(request,[request[@"deadline"] doubleValue]),@"request rejects exact deadline");
    }
    for(id bad in @[NSNull.null,@[],@YES,@42,@"wrong"])Check(BadRequest(bad),@"non-dictionaries fail safely");
    for(id value in @[@YES,@1.0,@0,@2,@"1"])Check(BadRequest(Replace(create,@"version",value)),@"version rejects coercion");
    for(id value in @[@YES,@"24",@(NAN),@(INFINITY),@(LBXContainerMutationIPCClock()-1),@(LBXContainerMutationIPCClock()+26)])Check(BadRequest(Replace(create,@"deadline",value)),@"deadline rejects invalid or unbounded values");
    Check(!LBXContainerMutationIPCValidateRequest(create,NAN)&&!LBXContainerMutationIPCValidateRequest(create,-1),@"bad local clocks reject");
    NSArray *epochs=@[NSNull.null,@1,@YES,@"",@"0",@"00",@"01",@"-1",@"+1",@"1.0",@"1e2",@" 1",@"1 ",@"１２",@"9223372036854775808",@"99999999999999999999"];
    for(id value in epochs){Check(BadRequest(Replace(create,@"expectedEmptyEpoch",value)),@"stage epoch is canonical positive bounded decimal string");Check(BadRequest(Replace(execute,@"epoch",value)),@"slot epoch rejects coercion");}
    for(NSString *value in @[@"1",@"9007199254740993",@"9223372036854775807"]){Check(!BadRequest(Replace(create,@"expectedEmptyEpoch",value)),@"canonical epoch retains precision above JSON numeric range");}
    NSArray *uuids=@[NSNull.null,@YES,@"bad",stageID.uppercaseString,@"00000000-0000-0000-0000-000000000000"];
    for(id value in uuids){Check(BadRequest(Replace(create,@"stageRequestID",value)),@"stage ID must be canonical nonzero UUID");Check(BadRequest(Replace(execute,@"token",value)),@"slot token must be canonical UUID");}
    for(NSString *key in choices)Check(BadRequest(Replace(create,@"choices",Replace(choices,key,nil))),@"all choices required");
    Check(!BadRequest(Replace(create,@"choices",Replace(choices,@"proxyReference",stageID))),@"canonical opaque proxy handle is authored metadata only");
    Check(BadRequest(Replace(create,@"choices",Replace(choices,@"proxyReference",@"http://password@host"))),@"proxy credentials cannot cross wire");
    Check(BadRequest(Replace(create,@"choices",Replace(choices,@"manualIdentifiers",@{}))),@"partial manual choices reject");
    Check(BadRequest(Replace(create,@"choices",Replace(choices,@"extra",@1))),@"choices reject unknown keys");
    NSDictionary *randomChoices=@{@"name":random.name,@"applications":apps,@"manualIdentifiers":NSNull.null,@"proxyReference":@""};
    NSDictionary *randomRequest=LBXContainerMutationIPCRequest(@"stage-create",@{@"expectedEmptyEpoch":@"1",@"stageRequestID":NSUUID.UUID.UUIDString.lowercaseString,@"choices":randomChoices});
    NSDictionary *randomSlot=Slot(random.privateDictionary,nil,@"2",randomRequest[@"stageRequestID"]);
    Check(!BadRequest(randomRequest),@"random request generates no identity");
    Check(BadRequest(Replace(update,@"configuration",manual.privateDictionary)),@"update must advance revision");
    Check(BadRequest(Replace(update,@"expected",updated.privateDictionary)),@"update exact prior cannot equal candidate");
    Check(BadRequest(Replace(update,@"configuration",Replace(updated.privateDictionary,@"identifier",random.identifier))),@"update retains full stable UUID");
    Check(!BadRequest(Replace(update,@"configuration",Replace(updated.privateDictionary,@"proxyReference",stageID))),@"exact update accepts canonical reference metadata without resolver authority");
    Check(!LBXContainerMutationIPCRequest(@"execute",@{@"token":slot[@"token"],@"epoch":@"2",@"configuration":manual.privateDictionary}),@"execute accepts token and epoch only");
    Check(!LBXContainerMutationIPCRequest(@"status",@{@"deadline":@1}),@"factory cannot replace fresh envelope");
    NSDictionary *again=LBXContainerMutationIPCRequest(@"stage-create",@{@"expectedEmptyEpoch":@"1",@"stageRequestID":stageID,@"choices":choices});
    Check(![again[@"requestID"] isEqual:create[@"requestID"]]&&[again[@"stageRequestID"] isEqual:stageID],@"repeat stage keeps stable ID but gets fresh wire ID");
    NSDictionary *staged=LBXContainerMutationIPCReply(create,@"staged",pending,manual.privateDictionary,nil,nil);
    NSDictionary *saved=LBXContainerMutationIPCReply(execute,@"saved",completed,manual.privateDictionary,nil,nil);
    NSDictionary *retry=LBXContainerMutationIPCReply(reconcile,@"retry_required",pending,manual.privateDictionary,nil,nil);
    NSDictionary *record=LBXContainerMutationIPCReply(read,@"record",pending,manual.privateDictionary,nil,nil);
    NSDictionary *empty=LBXContainerMutationIPCReply(status,@"status",State(@"1",nil,nil),nil,nil,nil);
    NSDictionary *listed=LBXContainerMutationIPCReply(list,@"listed",pending,nil,@[],@"");
    NSArray *pairs=@[@[create,staged,@"staged"],@[execute,saved,@"saved"],@[reconcile,retry,@"retry_required"],@[read,record,@"record"],@[status,empty,@"status"],@[list,listed,@"listed"]];
    for(NSArray *pair in pairs){
        NSDictionary *request=pair[0],*reply=pair[1];Check([reply[@"result"] isEqual:pair[2]]&&!BadReply(reply,request),@"exact successful reply retains result and typed state");
        for(NSString *field in @[@"family",@"version",@"requestID",@"operation",@"result",@"state",@"configuration",@"entries",@"next",@"runtimeAccepted"])Check(BadReply(Replace(reply,field,nil),request),@"all reply fields mandatory");
        for(NSString *field in @[@"UID",@"key",@"deviceID",@"receipt",@"context",@"path",@"generation",@"attempt",@"engineAuthorized"])Check(BadReply(Replace(reply,field,@1),request),@"reply cannot disclose credentials context paths or grant flags");
        for(id flag in @[@YES,@0,@1,@"false",NSNull.null])Check(BadReply(Replace(reply,@"runtimeAccepted",flag),request),@"runtime flag is strict Boolean false");
        Check(BadReply(Replace(reply,@"requestID",NSUUID.UUID.UUIDString.lowercaseString),request),@"reply cannot replace wire correlation");
        Check(BadReply(Replace(reply,@"operation",@"unknown"),request),@"reply cannot cross operation");
        Check(!LBXContainerMutationIPCValidateReply(reply,request,[request[@"deadline"] doubleValue]),@"late reply rejects");
    }
    Check(!BadReply(LBXContainerMutationIPCReply(randomRequest,@"staged",State(@"2",randomSlot,nil),random.privateDictionary,nil,nil),randomRequest),@"random stage matches requested mode and canonical choices");
    Check(!BadReply(LBXContainerMutationIPCReply(create,@"saved",completed,manual.privateDictionary,nil,nil),create),@"completed duplicate stage may confirm exact original manual input");
    Check(!BadReply(LBXContainerMutationIPCReply(again,@"saved",completed,manual.privateDictionary,nil,nil),again),@"same stable stage repeat accepts fresh correlated saved reply");
    Check(BadReply(Replace(staged,@"configuration",random.privateDictionary),create),@"top candidate cannot differ from staged slot");
    Check(BadReply(Replace(staged,@"state",State(@"4",Replace(slot,@"stageRequestID",NSUUID.UUID.UUIDString.lowercaseString),nil)),create),@"stage reply retains exact stable request ID");
    Check(BadReply(Replace(staged,@"state",State(@"4",Replace(slot,@"epoch",@"3"),nil)),create),@"immutable staging epoch derives from expected empty CAS");
    Check(BadReply(Replace(staged,@"state",State(@"4",Replace(slot,@"configuration",random.privateDictionary),nil)),create),@"manual stage reply cannot replace chosen values");
    Check(BadReply(Replace(staged,@"state",completed),create),@"staged must be pending rather than completed");
    Check(BadReply(Replace(saved,@"state",pending),execute),@"saved cannot claim completion of pending state");
    Check(BadReply(Replace(saved,@"state",newPending),execute),@"newer pending refuses old completion saved claim");
    Check(!BadReply(LBXContainerMutationIPCReply(execute,@"conflict",newPending,nil,nil,nil),execute),@"old token conflict can show current private state without resurrecting it");
    Check(BadReply(Replace(saved,@"state",State(@"5",nil,Replace(slot,@"token",NSUUID.UUID.UUIDString.lowercaseString))),execute),@"completion must match exact requested token");
    Check(BadReply(Replace(saved,@"state",State(@"5",nil,Replace(slot,@"epoch",@"3"))),execute),@"completion must match immutable requested epoch");
    Check(!BadReply(LBXContainerMutationIPCReply(status,@"status",newPending,nil,nil,nil),status),@"status can show prior completion with newer pending");
    for(NSDictionary *invalid in @[Replace(pending,@"epoch",@"1"),Replace(pending,@"pending",Replace(slot,@"context",@{})),Replace(pending,@"pending",Replace(slot,@"expected",manual.privateDictionary)),State(@"7",slot,slot),State(@"7",slot,newSlot)]){
        Check(!LBXContainerMutationIPCProjectState(invalid)&&BadReply(Replace(staged,@"state",invalid),create),@"invalid private projections cannot be normalized into authority");
    }
    for(NSString *field in slot)Check(!LBXContainerMutationIPCProjectSlot(Replace(slot,field,nil)),@"all slot projection fields required");
    for(NSString *field in pending)Check(!LBXContainerMutationIPCProjectState(Replace(pending,field,nil)),@"all state fields required");
    Check(LBXContainerMutationIPCProjectSlot(slot)&&LBXContainerMutationIPCProjectState(pending),@"strict projected snapshots accepted");
    for(NSString *result in @[@"conflict",@"authorization_required",@"storage_unavailable",@"invalid_request",@"service_unavailable",@"unconfirmed"]){
        NSDictionary *failure=LBXContainerMutationIPCFailure(execute,result);Check(!BadReply(failure,execute),@"fixed empty failure is correlated");
        Check(failure[@"state"]==NSNull.null&&failure[@"configuration"]==NSNull.null,@"unsafe/unauthorized is unknown rather than verified empty");
        Check(BadReply(Replace(failure,@"configuration",manual.privateDictionary),execute),@"failure cannot substitute completion candidate");
    }
    Check(!BadReply(LBXContainerMutationIPCReply(execute,@"unconfirmed",pending,nil,nil,nil),execute),@"uncertain publication may retain exact private pending projection");
    Check(BadReply(Replace(LBXContainerMutationIPCFailure(execute,@"authorization_required"),@"state",pending),execute),@"denial cannot disclose a state projection");
    Check([LBXContainerMutationIPCFailure(execute,@"saved")[@"result"] isEqual:@"service_unavailable"],@"failure helper cannot forge saved");
    Check([LBXContainerMutationIPCFailure(read,@"missing")[@"result"] isEqual:@"service_unavailable"],@"missing requires inspected strict state");
    Check(!BadReply(LBXContainerMutationIPCReply(read,@"missing",pending,nil,nil,nil),read),@"missing result only follows licensed read with state");
    Check(BadReply(Replace(record,@"configuration",random.privateDictionary),read),@"read result must match exact requested UUID");
    NSMutableArray *page=[NSMutableArray array];NSString *unicode=[@"界" stringByPaddingToLength:80 withString:@"界" startingAtIndex:0];
    for(NSUInteger index=1;index<=40;index++)[page addObject:@{@"identifier":[NSString stringWithFormat:@"00000000-0000-4000-8000-%012lu",(unsigned long)index],@"revision":@(LLONG_MAX),@"name":unicode,@"applications":apps}];
    NSString *last=page.lastObject[@"identifier"];NSDictionary *full=LBXContainerMutationIPCReply(list,@"listed",newPending,nil,page,last);
    Check(!BadReply(full,list)&&[NSJSONSerialization dataWithJSONObject:full options:0 error:nil].length>16384,@"forty Unicode records plus private state fit larger reply bound");
    Check(BadReply(Replace(full,@"next",page.firstObject[@"identifier"]),list),@"cursor matches last of full page");
    Check(BadReply(Replace(full,@"entries",[[page reverseObjectEnumerator] allObjects]),list),@"unordered page rejects");
    NSMutableArray *duplicate=[page mutableCopy];duplicate[1]=duplicate[0];Check(BadReply(Replace(full,@"entries",duplicate),list),@"duplicate IDs reject");
    NSMutableArray *tooMany=[page mutableCopy];[tooMany addObject:page[0]];Check(BadReply(Replace(full,@"entries",tooMany),list),@"page limit40");
    Check(BadReply(Replace(full,@"entries",@[page[0]]),list),@"short page cannot claim cursor");
    NSMutableArray *badPage=[page mutableCopy];badPage[0]=Replace(page[0],@"name",[@"x" stringByPaddingToLength:65536 withString:@"x" startingAtIndex:0]);
    Check(BadReply(Replace(full,@"entries",badPage),list),@"oversized reply rejects");
    NSArray *wrong=@[NSNull.null,@YES,@42,@1.5,@"wrong",@[NSNull.null],@{@"unexpected":@"value"}];
    for(NSString *key in @[@"family",@"version",@"requestID",@"operation",@"deadline",@"choices",@"expectedEmptyEpoch",@"stageRequestID"])
        for(id value in wrong)Check(BadRequest(Replace(create,key,value)),@"request fields reject incompatible types");
    for(NSString *key in @[@"family",@"version",@"requestID",@"operation",@"result",@"state",@"configuration",@"entries",@"next",@"runtimeAccepted"])
        for(id value in wrong)Check(BadReply(Replace(staged,key,value),create),@"reply fields reject incompatible types");
    NSMutableDictionary *mutableChoices=[choices mutableCopy];NSMutableArray *mutableApps=[apps mutableCopy];mutableChoices[@"applications"]=mutableApps;
    NSDictionary *snapshot=LBXContainerMutationIPCRequest(@"stage-create",@{@"expectedEmptyEpoch":@"1",@"stageRequestID":stageID,@"choices":mutableChoices});
    [mutableApps removeAllObjects];mutableChoices[@"name"]=@"changed";
    Check([snapshot[@"choices"][@"applications"] count]==3&&[snapshot[@"choices"][@"name"] isEqual:manual.name],@"request snapshot retains all nested inputs");
    ProxyMetadataTests(manual);
    Check(Generations==0,@"protocol validation never generates an identity or effects storage");
    method_setImplementation(generator,original);
    NSLog(@"%@: %lu root mutation IPC assertions, %lu failures",Failures?@"FAIL":@"PASS",(unsigned long)Checks,(unsigned long)Failures);return Failures?1:0;
}}
