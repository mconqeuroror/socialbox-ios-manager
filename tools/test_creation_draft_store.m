#import <Foundation/Foundation.h>
#import <math.h>
#import "RBXCreationDraftStore.h"

static NSUInteger Checks;
static void Check(BOOL value, NSString *label) {
 Checks++; if(!value){fprintf(stderr,"FAIL: %s\n",label.UTF8String);exit(1);}
}
static NSDictionary *Metadata(NSString *identifier) {
 return @{@"container":identifier,@"appType":@"reddit",@"nickname":@"Preview",@"country":@"US",@"role":@"default"};
}
static NSDictionary *Envelope(NSTimeInterval now) {
 return @{@"formatVersion":@1,@"preparedAt":@(now),@"profile":@{@"containerId":@"profile-a",@"privateValue":@"PRIVATE_PROFILE_SECRET"},
  @"review":@{@"marketingName":@"Test model",@"country":@"US"}};
}
static NSDictionary *Binding(void) {
 return @{@"source":@{@"inode":@7},@"proxy":@{@"proxyURL":@"http://private:PRIVATE_PROXY_SECRET@proxy.example:8080"},@"account":@"PRIVATE_ACCOUNT_SECRET"};
}
static NSDictionary *Get(NSMutableDictionary *store,NSDictionary *record,NSTimeInterval now) {
 return RBXCreationGetDraft(store,record[@"token"],@"profile-a",@"reddit",record[@"revision"],Binding(),now,nil);
}
int main(void){@autoreleasepool{
 NSMutableDictionary *store=[NSMutableDictionary dictionary];
 NSDictionary *record=RBXCreationStoreDraft(store,Envelope(1000),Metadata(@"profile-a"),Binding(),1000,nil);
 Check(record && store.count==1,@"one ephemeral record stored");
 Check([[NSUUID alloc] initWithUUIDString:record[@"token"]]!=nil && [record[@"revision"] isEqual:@1],@"opaque token and initial revision");
 Check([Get(store,record,1001) isEqual:record],@"exact binding resolves");
 Check(!RBXCreationGetDraft(store,@"missing",@"profile-a",@"reddit",@1,Binding(),1001,nil),@"unknown token denied");
 Check(!RBXCreationGetDraft(store,record[@"token"],@"other",@"reddit",@1,Binding(),1001,nil),@"wrong container denied");
 Check(!RBXCreationGetDraft(store,record[@"token"],@"profile-a",@"facebook",@1,Binding(),1001,nil),@"wrong app denied");
 Check(!RBXCreationGetDraft(store,record[@"token"],@"profile-a",@"reddit",@2,Binding(),1001,nil),@"wrong revision denied");
 Check(!RBXCreationGetDraft(store,record[@"token"],@"profile-a",@"reddit",@1,nil,1001,nil),@"missing binding denied");
 for(NSString *field in @[@"source",@"proxy",@"account"]) {
  NSMutableDictionary *changed=Binding().mutableCopy;changed[field]=@"changed";
  Check(!RBXCreationGetDraft(store,record[@"token"],@"profile-a",@"reddit",@1,changed,1001,nil),@"changed dependency invalidates exact review");
 }
 NSDictionary *public=RBXCreationPublicReview(record);
 NSSet *keys=[NSSet setWithArray:public.allKeys];
 Check([keys isEqual:[NSSet setWithArray:@[@"creationDraftToken",@"creationDraftRevision",@"containerId",@"appType",@"expiresAt",@"review"]]],@"public projection has only documented keys");
 Check(![public.description containsString:@"PRIVATE_"],@"profile, credentials and account binding never enter public review");
 Check([public[@"expiresAt"] isEqual:@1300],@"five-minute expiry published");
 NSMutableDictionary *envelope=[Envelope(1000) mutableCopy];
 NSMutableDictionary *profile=[envelope[@"profile"] mutableCopy], *review=[envelope[@"review"] mutableCopy];
 envelope[@"profile"]=profile;envelope[@"review"]=review;
 NSMutableDictionary *metadata=[Metadata(@"profile-a") mutableCopy],*binding=[Binding() mutableCopy];
 [store removeAllObjects];record=RBXCreationStoreDraft(store,envelope,metadata,binding,1000,nil);
 profile[@"privateValue"]=@"changed";review[@"country"]=@"GB";metadata[@"container"]=@"changed";binding[@"account"]=@"changed";
 Check([record[@"envelope"][@"profile"][@"privateValue"] isEqual:@"PRIVATE_PROFILE_SECRET"],@"profile copy detached from caller");
 Check([record[@"envelope"][@"review"][@"country"] isEqual:@"US"]&&[record[@"metadata"][@"container"] isEqual:@"profile-a"],@"nested review and metadata detached");
 Check([Get(store,record,1001) isEqual:record],@"binding copy detached from caller");
 NSMutableDictionary *edited=[Envelope(1000) mutableCopy];edited[@"review"]=@{@"marketingName":@"Edited model",@"country":@"US"};
 NSDictionary *updated=RBXCreationUpdateDraft(store,record,edited,nil);
 Check(updated&&[updated[@"revision"] isEqual:@2],@"edit increments revision");
 Check([updated[@"token"] isEqual:record[@"token"]]&&[updated[@"binding"] isEqual:record[@"binding"]],@"edit preserves token and source/proxy/account binding");
 Check(!Get(store,record,1001)&&Get(store,updated,1001),@"old reviewed revision cannot commit after edit");
 Check(!RBXCreationUpdateDraft(store,record,edited,nil),@"stale editor cannot overwrite newer review");
 Check([RBXCreationGetDraft(store,record[@"token"],@"profile-a",@"reddit",nil,Binding(),1001,nil) isEqual:updated],@"read-only review can load latest revision");
 edited[@"review"]=@{@"marketingName":@"Mutated after save"};
 Check([updated[@"envelope"][@"review"][@"marketingName"] isEqual:@"Edited model"],@"updated envelope detached from caller");
 edited[@"preparedAt"]=@1001;
 Check(!RBXCreationUpdateDraft(store,updated,edited,nil),@"editing cannot extend observation lifetime");
 Check([RBXCreationPublicReview(updated)[@"expiresAt"] isEqual:@1300],@"edit expiry unchanged");
 Check(Get(store,updated,1299.999)!=nil,@"valid until original expiry");
 Check(!Get(store,updated,1300)&&store.count==0,@"expiry prunes at exact boundary");
 record=RBXCreationStoreDraft(store,Envelope(1000),Metadata(@"profile-a"),Binding(),1000,nil);
 Check(!Get(store,record,999)&&store.count==0,@"backwards clock cannot resurrect future observation");
 Check(!RBXCreationStoreDraft(store,Envelope(1001),Metadata(@"profile-a"),Binding(),1000,nil),@"future observation rejected");
 Check(!RBXCreationStoreDraft(store,Envelope(700),Metadata(@"profile-a"),Binding(),1000,nil),@"expired observation rejected at insert");
 Check(!RBXCreationStoreDraft(store,Envelope(1000),Metadata(@"profile-a"),@{},1000,nil),@"unbound draft rejected");
 for(NSUInteger i=0;i<8;i++)Check(RBXCreationStoreDraft(store,Envelope(1000),Metadata(@"profile-a"),Binding(),1000,nil)!=nil,@"bounded slots available");
 Check(store.count==8&&!RBXCreationStoreDraft(store,Envelope(1000),Metadata(@"profile-a"),Binding(),1000,nil),@"ninth concurrent draft refused without eviction");
 record=RBXCreationStoreDraft(store,Envelope(1301),Metadata(@"profile-a"),Binding(),1301,nil);
 Check(record&&store.count==1,@"expired slots pruned before new preparation");
 [store removeObjectForKey:record[@"token"]];
 Check(!Get(store,record,1302)&&!RBXCreationUpdateDraft(store,record,Envelope(1301),nil),@"consumed or discarded token cannot replay or update");
 // The source generator uses NSDate, but the authority helper must reject an
 // invalid clock or malformed persisted numeric value rather than grant an
 // unbounded lifetime. These are boundary tests, not a claimed external attack.
 Check(!RBXCreationStoreDraft(store,Envelope(NAN),Metadata(@"profile-a"),Binding(),1000,nil),@"NaN prepared time rejected");
 Check(!RBXCreationStoreDraft(store,Envelope(1000),Metadata(@"profile-a"),Binding(),NAN,nil),@"NaN clock rejected at insert");
 record=RBXCreationStoreDraft(store,Envelope(1000),Metadata(@"profile-a"),Binding(),1000,nil);
 Check(!Get(store,record,NAN),@"NaN clock cannot authorize a draft");
 fprintf(stdout,"PASS creation draft store: %lu checks; scope, binding, revision, expiry, replay, immutable copies, eight-draft bound and private projection.\n",(unsigned long)Checks);
}return 0;}
